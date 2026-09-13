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

local os_time = os.time
local os_date = os.date
local str_format = string.format
local tonumber = tonumber

local _M = {}

-- 计算自然时间窗口的 TTL 和标签
-- @param period 时间周期："day", "month", "year" 或固定秒数
-- @return ttl_seconds 到窗口结束的秒数
-- @return window_label 窗口标签（用于 key 隔离）
function _M.calc_natural_window(period)
    local now = ngx.time()
    local t = os_date("*t", now)

    if period == "day" then
        -- 今天 23:59:59
        local end_ts = os_time({
            year = t.year,
            month = t.month,
            day = t.day,
            hour = 23,
            min = 59,
            sec = 59
        })
        local label = str_format("%04d%02d%02d", t.year, t.month, t.day)
        return end_ts - now, label

    elseif period == "month" then
        -- 本月最后一天 23:59:59
        local next_month = t.month == 12 and 1 or t.month + 1
        local next_year = t.month == 12 and t.year + 1 or t.year
        local end_ts = os_time({
            year = next_year,
            month = next_month,
            day = 1,
            hour = 0,
            min = 0,
            sec = 0
        }) - 1
        local label = str_format("%04d%02d", t.year, t.month)
        return end_ts - now, label

    elseif period == "year" then
        -- 本年 12 月 31 日 23:59:59
        local end_ts = os_time({
            year = t.year,
            month = 12,
            day = 31,
            hour = 23,
            min = 59,
            sec = 59
        })
        local label = str_format("%04d", t.year)
        return end_ts - now, label

    else
        -- 固定秒数（向后兼容）
        local seconds = tonumber(period)
        if not seconds or seconds <= 0 then
            return nil, "invalid period: " .. tostring(period)
        end
        return seconds, tostring(seconds)
    end
end

return _M
