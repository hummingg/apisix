#
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

use t::APISIX 'no_plan';

log_level("info");
repeat_each(1);
no_long_string();
no_root_location();

run_tests();

__DATA__

=== TEST 1: 设置路由（使用 local 策略）
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                ngx.HTTP_PUT,
                [[{
                    "plugins": {
                        "ai-token-limit": {
                            "rules": [
                                {
                                    "token_type": "total_tokens",
                                    "period": "day",
                                    "limit": 100,
                                    "key": "consumer_name",
                                    "key_type": "var"
                                }
                            ],
                            "policy": "local"
                        }
                    },
                    "upstream": {
                        "nodes": {
                            "127.0.0.1:1980": 1
                        },
                        "type": "roundrobin"
                    },
                    "uri": "/hello"
                }]]
                )

            if code >= 300 then
                ngx.status = code
            end
            ngx.say(body)
        }
    }
--- request
GET /t
--- response_body
passed



=== TEST 2: 验证插件 schema
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.ai-token-limit")
            local ok, err = plugin.check_schema({
                rules = {
                    {
                        token_type = "total_tokens",
                        period = "day",
                        limit = 100,
                        key = "consumer_name",
                        key_type = "var"
                    }
                },
                policy = "local"
            })
            if not ok then
                ngx.say(err)
            else
                ngx.say("passed")
            end
        }
    }
--- request
GET /t
--- response_body
passed



=== TEST 3: 测试多维度 key（var_combination）
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/2',
                ngx.HTTP_PUT,
                [[{
                    "plugins": {
                        "ai-token-limit": {
                            "rules": [
                                {
                                    "token_type": "total_tokens",
                                    "period": 86400,
                                    "limit": 1000,
                                    "key": "$consumer_name-$remote_addr",
                                    "key_type": "var_combination"
                                }
                            ],
                            "policy": "local"
                        }
                    },
                    "upstream": {
                        "nodes": {
                            "127.0.0.1:1980": 1
                        },
                        "type": "roundrobin"
                    },
                    "uri": "/test"
                }]]
                )

            if code >= 300 then
                ngx.status = code
            end
            ngx.say(body)
        }
    }
--- request
GET /t
--- response_body
passed



=== TEST 4: 测试 constant key
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.ai-token-limit")
            local ok, err = plugin.check_schema({
                rules = {
                    {
                        token_type = "prompt_tokens",
                        period = "month",
                        limit = 50000,
                        key = "global",
                        key_type = "constant"
                    }
                },
                policy = "local"
            })
            if not ok then
                ngx.say(err)
            else
                ngx.say("passed")
            end
        }
    }
--- request
GET /t
--- response_body
passed



=== TEST 5: 测试无效的 token_type
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.ai-token-limit")
            local ok, err = plugin.check_schema({
                rules = {
                    {
                        token_type = "invalid_type",
                        period = "day",
                        limit = 100
                    }
                },
                policy = "local"
            })
            if not ok then
                ngx.say("validation failed")
            else
                ngx.say("passed")
            end
        }
    }
--- request
GET /t
--- response_body
validation failed

