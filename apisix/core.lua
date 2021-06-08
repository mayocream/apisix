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
local log = require("apisix.core.log")
local utils = require("apisix.core.utils")
-- 本地配置文件
local local_conf, err = require("apisix.core.config_local").local_conf()
if not local_conf then
    error("failed to parse yaml config: " .. err)
end

local config_center = local_conf.apisix and local_conf.apisix.config_center -- etcd / yaml
                      or "etcd"
log.info("use config_center: ", config_center)
local config = require("apisix.core.config_" .. config_center)
config.type = config_center


return {
    -- 版本号常量
    version     = require("apisix.core.version"),
    -- 日志包封装, 这里比 kong 封装的清晰太多
    log         = log,
    -- 配置文件, 本地或者远程 (etcd)
    config      = config,
    -- 工具类
    config_util = require("apisix.core.config_util"),
    sleep       = utils.sleep,
    json        = require("apisix.core.json"),
    table       = require("apisix.core.table"),
    -- 封装 request
    request     = require("apisix.core.request"),
    -- 封装 response
    response    = require("apisix.core.response"),
    -- 封装 lrucache
    lrucache    = require("apisix.core.lrucache"),
    -- 定义 schema 类型以及 jsonschema 验证器
    schema      = require("apisix.schema_def"),
    string      = require("apisix.core.string"),
    ctx         = require("apisix.core.ctx"),
    timer       = require("apisix.core.timer"),
    id          = require("apisix.core.id"),
    utils       = utils,
    -- 封装 resty.dns.client
    dns_client  = require("apisix.core.dns.client"),
    etcd        = require("apisix.core.etcd"),
    tablepool   = require("tablepool"),
    -- dns 解析工具库
    resolver    = require("apisix.core.resolver"),
    os          = require("apisix.core.os"),
    empty_tab   = {},
}
