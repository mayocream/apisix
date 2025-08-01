--
-- Licensed to the Apache Software Foundation (ASF) under one or more
-- contributor license agreements.  See the NOTICE file distributed with
-- this work for additional information regarding copyright ownership.
-- The ASF licenses this file to You under the Apache License, Version 2.0
-- (the "License"); you may not use this file except in compliance with
-- the License.  You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--

--- Collection of util functions.
--
-- @module core.utils

local config_local   = require("apisix.core.config_local")
local core_str       = require("apisix.core.string")
local rfind_char     = core_str.rfind_char
local table          = require("apisix.core.table")
local log            = require("apisix.core.log")
local string         = require("apisix.core.string")
local dns_client     = require("apisix.core.dns.client")
local ngx_re         = require("ngx.re")
local ipmatcher      = require("resty.ipmatcher")
local ffi            = require("ffi")
local base           = require("resty.core.base")
local open           = io.open
local sub_str        = string.sub
local str_byte       = string.byte
local str_gsub       = string.gsub
local tonumber       = tonumber
local tostring       = tostring
local re_gsub        = ngx.re.gsub
local re_match       = ngx.re.match
local re_gmatch      = ngx.re.gmatch
local type           = type
local C              = ffi.C
local ffi_string     = ffi.string
local ffi_new        = ffi.new
local get_string_buf = base.get_string_buf
local exiting        = ngx.worker.exiting
local ngx_sleep      = ngx.sleep
local ipairs         = ipairs

local hostname
local dns_resolvers
local current_inited_resolvers
local current_dns_client
local max_sleep_interval = 1

ffi.cdef[[
    int ngx_escape_uri(char *dst, const char *src,
        size_t size, int type);
    int gethostname(char *name, size_t len);
    char *strerror(int errnum);
]]


local _M = {
    version = 0.2,
    parse_ipv4 = ipmatcher.parse_ipv4,
    parse_ipv6 = ipmatcher.parse_ipv6,
}


function _M.get_seed_from_urandom()
    local frandom, err = open("/dev/urandom", "rb")
    if not frandom then
        return nil, 'failed to open /dev/urandom: ' .. err
    end

    local str = frandom:read(8)
    frandom:close()
    if not str then
        return nil, 'failed to read data from /dev/urandom'
    end

    local seed = 0
    for i = 1, 8 do
        seed = 256 * seed + str:byte(i)
    end

    return seed
end


function _M.split_uri(uri)
    return ngx_re.split(uri, "/")
end


local function dns_parse(domain, selector)
    if dns_resolvers ~= current_inited_resolvers then
        local local_conf = config_local.local_conf()
        local valid = table.try_read_attr(local_conf, "apisix", "dns_resolver_valid")
        local enable_resolv_search_opt = table.try_read_attr(local_conf, "apisix",
                                                             "enable_resolv_search_opt")
        local opts = {
            nameservers = table.clone(dns_resolvers),
            order = {"last", "A", "AAAA", "CNAME"}, -- avoid querying SRV
        }

        opts.validTtl = valid

        if not enable_resolv_search_opt then
            opts.search = {}
        end

        local client, err = dns_client.new(opts)
        if not client then
            return nil, "failed to init the dns client: " .. err
        end

        current_dns_client = client
        current_inited_resolvers = dns_resolvers
    end

    return current_dns_client:resolve(domain, selector)
end
_M.dns_parse = dns_parse


local function set_resolver(resolvers)
    dns_resolvers = resolvers
end
_M.set_resolver = set_resolver


function _M.get_resolver(resolvers)
    return dns_resolvers
end


local function _parse_ipv4_or_host(addr)
    local pos = rfind_char(addr, ":", #addr - 1)
    if not pos then
        return addr, nil
    end

    local host = sub_str(addr, 1, pos - 1)
    local port = sub_str(addr, pos + 1)
    return host, tonumber(port)
end


local function _parse_ipv6_without_port(addr)
    return addr
end


-- parse_addr parses 'addr' into the host and the port parts. If the 'addr'
-- doesn't have a port, nil is used to return.
-- For IPv6 literal host with brackets, like [::1], the square brackets will be kept.
-- For malformed 'addr', the returned value can be anything. This method doesn't validate
-- if the input is valid.
function _M.parse_addr(addr)
    if str_byte(addr, 1) == str_byte("[") then
        -- IPv6 format, with brackets, maybe with port
        local right_bracket = str_byte("]")
        local len = #addr
        if str_byte(addr, len) == right_bracket then
            -- addr in [ip:v6] format
            return addr, nil
        else
            local pos = rfind_char(addr, ":", #addr - 1)
            if not pos or str_byte(addr, pos - 1) ~= right_bracket then
                -- malformed addr
                return addr, nil
            end

            -- addr in [ip:v6]:port format
            local host = sub_str(addr, 1, pos - 1)
            local port = sub_str(addr, pos + 1)
            return host, tonumber(port)
        end

    else
        -- When we reach here, the input can be:
        -- 1. IPv4
        -- 2. IPv4, with port
        -- 3. IPv6, like "2001:db8::68" or "::ffff:192.0.2.1"
        -- 4. Malformed input
        -- 5. Host, like "test.com" or "localhost"
        -- 6. Host with port
        local colon = str_byte(":")
        local colon_counter = 0
        local dot = str_byte(".")
        for i = 1, #addr do
            local ch = str_byte(addr, i, i)
            if ch == dot then
                return _parse_ipv4_or_host(addr)
            elseif ch == colon then
                colon_counter = colon_counter + 1
                if colon_counter == 2 then
                    return _parse_ipv6_without_port(addr)
                end
            end
        end

        return _parse_ipv4_or_host(addr)
    end
end


function _M.uri_safe_encode(uri)
    local count_escaped = C.ngx_escape_uri(nil, uri, #uri, 0)
    local len = #uri + 2 * count_escaped
    local buf = get_string_buf(len)
    C.ngx_escape_uri(buf, uri, #uri, 0)

    return ffi_string(buf, len)
end


function _M.validate_header_field(field)
    for i = 1, #field do
        local b = str_byte(field, i, i)
        -- '!' - '~', excluding ':'
        if not (32 < b and b < 127) or b == 58 then
            return false
        end
    end
    return true
end


function _M.validate_header_value(value)
    if type(value) ~= "string" then
        return true
    end

    for i = 1, #value do
        local b = str_byte(value, i, i)
        -- control characters
        if b < 32 or b >= 127 then
            return false
        end
    end
    return true
end


---
-- Returns the standard host name of the local host.
-- only use this method in init/init_worker phase.
--
-- @function core.utils.gethostname
-- @treturn string The host name of the local host.
-- @usage
-- local hostname = core.utils.gethostname() -- "localhost"
function _M.gethostname()
    if hostname then
        return hostname
    end

    local size = 256
    local buf = ffi_new("unsigned char[?]", size)

    local res = C.gethostname(buf, size)
    if res == 0 then
        local data = ffi_string(buf, size)
        hostname = str_gsub(data, "%z+$", "")

    else
        hostname = "unknown"
        log.error("failed to call gethostname(): ", ffi_string(C.strerror(ffi.errno())))
    end

    return hostname
end


local function sleep(sec)
    if sec <= max_sleep_interval then
        return ngx_sleep(sec)
    end
    ngx_sleep(max_sleep_interval)
    if exiting() then
        return
    end
    sec = sec - max_sleep_interval
    return sleep(sec)
end


_M.sleep = sleep


local resolve_var
do
    local _ctx
    local n_resolved
    local pat = [[(?<!\\)\$(\{([\w\.]+)\}|([\w\.]+))]]
    local _escaper

    local function resolve(m)
        local variable = m[2] or m[3]
        local v = _ctx[variable]

        if v == nil then
            return ""
        end
        n_resolved = n_resolved + 1
        if _escaper then
            return _escaper(tostring(v))
        end
        return tostring(v)
    end

    function resolve_var(tpl, ctx, escaper)
        n_resolved = 0
        if not tpl then
            return tpl, nil, n_resolved
        end

        local from = core_str.find(tpl, "$")
        if not from then
            return tpl, nil, n_resolved
        end

        -- avoid creating temporary function
        _ctx = ctx
        _escaper = escaper
        local res, _, err = re_gsub(tpl, pat, resolve, "jo")
        _ctx = nil
        _escaper = nil
        if not res then
            return nil, err
        end

        return res, nil, n_resolved
    end
end
-- Resolve ngx.var in the given string
_M.resolve_var = resolve_var


local resolve_var_with_captures
do
    local _captures
    -- escape is not supported very well, like there is a redundant '\' after escape "$1"
    local pat = [[ (?<! \\) \$ \{? (\d+) \}? ]]

    local function resolve(m)
        local v = _captures[tonumber(m[1])]
        if not v then
            v = ""
        end
        return v
    end

    -- captures is the match result of regex uri in proxy-rewrite plugin
    function resolve_var_with_captures(tpl, captures)
        if not tpl then
            return tpl, nil
        end

        local from = core_str.find(tpl, "$")
        if not from then
            return tpl, nil
        end

        captures = captures or {}

        _captures = captures
        local res, _, err = re_gsub(tpl, pat, resolve, "jox")
        _captures = nil
        if not res then
            return nil, err
        end

        return res, nil
    end
end
-- Resolve {$1, $2, ...} in the given string
_M.resolve_var_with_captures = resolve_var_with_captures


-- if `str` is a string containing period `some_plugin.some_field.nested_field`
-- return the table that contains `nested_field` in its root level
-- else return the original table `conf`
local function get_root_conf(str, conf, field)
    -- if the string contains periods, get the splits in `it` iterator
    local it, _ = re_gmatch(str, [[([^\.]+)]])
    if not it then
        return conf, field
    end

    -- add the splits into a table
    local matches = {}
    while true do
        local m, _ = it()
        if not m then
            break
        end
        table.insert(matches, m[0])
    end

    -- get to the table that holds the last field
    local num_of_matches = #matches
    for i = 1, num_of_matches - 1 , 1 do
        conf = conf[matches[i]]
    end

    -- return the table and the last field
    return conf, matches[num_of_matches]
end


local function find_and_log(field, plugin_name, value)
    local match, err = re_match(value, "^https")
    if not match and not err then
        log.warn("Using ", plugin_name, " " , field, " with no TLS is a security risk")
    end
end


function _M.check_https(fields, conf, plugin_name)
    for _, field in ipairs(fields) do

        local new_conf, new_field = get_root_conf(field, conf)
        if not new_conf then
            return
        end

        local value = new_conf[new_field]
        if not value then
            return
        end

        if type(value) == "table" then
            for _, v in ipairs(value) do
                find_and_log(field, plugin_name, v)
            end
        else
            find_and_log(field, plugin_name, value)
        end
    end
end


function _M.check_tls_bool(fields, conf, plugin_name)
    for i, field in ipairs(fields) do

        local new_conf, new_field = get_root_conf(field, conf)
        if not new_conf then
            return
        end

        local value = new_conf[new_field]

        if value ~= true and value ~= nil then
            log.warn("Keeping ", field, " disabled in ",
                     plugin_name, " configuration is a security risk")
        end
    end
end


return _M
