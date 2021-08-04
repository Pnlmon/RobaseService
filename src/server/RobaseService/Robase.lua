local HttpWrapper = require(script.Parent.HttpWrapper)
local HttpService = game:GetService("HttpService")

local Robase = { }
Robase.__index = Robase

local Enum = {
    HttpMethod = {
        ["Default"] = "PUT",
        ["Put"] = "PUT",
        ["Get"] = "GET",
        ["Delete"] = "DELETE",
        ["Patch"] = "PATCH"
    }
}

local function deepcopy(orig)
        local orig_type = type(orig)
        local copy
        if orig_type == 'table' then
            copy = {}
            for orig_key, orig_value in next, orig, nil do
                copy[deepcopy(orig_key)] = deepcopy(orig_value)
            end
            setmetatable(copy, deepcopy(getmetatable(orig)))
        else -- number, string, boolean, etc
            copy = orig
        end
        return copy
    end

local function appendUrlQuery(url, queryName, queryData)
    if url:find("?") then
        return ("%s&%s=%s"):format(url, queryName, queryData)
    else
        return ("%s?%s=%s"):format(url, queryName, queryData)
    end
end

local function findHttpMethod(method)
    if method == nil then
        return nil
    end

    for key, value in pairs(Enum.HttpMethod) do
        if method:upper() ~= key:upper() or method:upper() ~= value:upper() then
            continue
        else
            return Enum.HttpMethod[key]
        end
    end
    return nil
end

local function generateRequestOptions(key, data, method, robase)
    if typeof(key)~="string" then
        error(string.format("Bad argument 1 string expected got %s", typeof(key)))
    end
    if data ~= nil then
        data = HttpService:JSONEncode(data)
    end
    if typeof(method)~="string" or findHttpMethod(method)==nil then
        warn(
            string.format(
                "Malformed argument 3, string expected, got %s; Defaulting to %s",
                typeof(method),
                Enum.HttpMethod.Default
            )
        )
        method = Enum.HttpMethod.Default
    end
    if typeof(robase)~="table" then
        error(string.format("Bad arument 4 table {Robase|self} expected got %s", typeof(robase)))
    end

    key = key:sub(1,1)~="/" and "/"..key or key
    local url = robase._path .. HttpService:UrlEncode(key) .. robase._auth
    local queryOption = robase._queryOption --cba to change all the stuff below
    
    if queryOption.shallow then
        url = appendUrlQuery(url, "shallow", tostring(queryOption.shallow))
    else --shallow cannot be used with any of the "filtering data" query parameters.
        if queryOption.orderBy then
            url = appendUrlQuery(url, "orderBy", queryOption.orderBy)
            --limitTo require orderBy
            
            if queryOption.limitToLast then
                url = appendUrlQuery(url, "limitToLast", queryOption.limitToLast)
            end
            
            if queryOption.limitToFirst then
                url = appendUrlQuery(url, "limitToFirst", queryOption.limitToFirst)
            end
            
            --Range Queries require orderBy
            
            if queryOption.startAt then
                url = appendUrlQuery(url, "startAt", queryOption.startAt)
            end
            
            if queryOption.endAt then
                url = appendUrlQuery(url, "endAt", queryOption.endAt)
            end
            
            if queryOption.equalTo then
                url = appendUrlQuery(url, "equalTo", queryOption.equalTo)
            end
        end
    end
        
    return {
        Url = url,
        Method = findHttpMethod(method),
        Body = data
    }
end

function Robase.new(path, robaseService)
    assert(path~=nil, "Cannot instantiate Robase without a specific path")
    assert(robaseService~=nil, "Cannot instatiate Robase without a linked RobaseService")

    local self = { }
    self._path = path
    self._queryOption = {}
    self._auth = robaseService.AuthKey
    self._robaseService = robaseService
    return setmetatable(self, Robase)
end

function Robase:Get(key)
    local options = generateRequestOptions(key, nil, "GET", self)
    return HttpWrapper:Request(options)
end

function Robase:Set(key, data, method)
    local options = generateRequestOptions(key, data, method, self)
    options.Headers = {
        ["Content-Type"] = "application/json"
    }
    return HttpWrapper:Request(options)
end

function Robase:GetAsync(key)
    local err
    local success, value = self:Get(key):catch(function(response)
        err = {response.StatusCode, response.StatusMessage}
    end):await()

    if not success then
        local msg = string.format("%d Error: %s", err[1], err[2])
        error(msg)
    end

    value = value and HttpService:JSONDecode(value) or nil
    return success, value
end

function Robase:SetAsync(key, data, method)
    local err
    local success, value = self:Set(key, data, method):catch(function(response)
        err = {response.StatusCode, response.StatusMessage}
    end):await()

    if not success then
        local msg = string.format("%d Error: %s", err[1], err[2])
        error(msg)
    end

    value = value and HttpService:JSONDecode(value) or nil
    return success,value
end

function Robase:UpdateAsync(key, callback, cache)
    assert(typeof(callback)=="function", "Bad argument 2 function expected got " .. typeof(callback))

    local success, data
    if cache~=nil and cache[key] then
        data = cache[key]
        success = (data~=nil)
    else
        success, data = self:GetAsync(key)
    end

    local updated = callback(data)

    return self:SetAsync(key, updated, "PATCH")
end

function Robase:DeleteAsync(key)
    local _, old = self:GetAsync(key)
    if old == nil then
        error(string.format(
            "No data found at key {%s}",
            key
            ))
    end

    local success, _ = self:SetAsync(key, "", "DELETE")
    return success, old
end

function Robase:IncrementAsync(key, delta)
    local _, data = self:GetAsync(key)

    if typeof(data)~="number" then -- not a number
        error(string.format(
            "IncrementAsync, data found at {%s} is not a number",
            key
            ))
    else -- is a number
        if math.floor(data) ~= data then -- not an integer
            error(string.format(
                "IncrementAsync, data found at {%s} is not an integer",
                key
                ))
        end
    end

    if typeof(delta) ~= "number" then -- not a number
        if typeof(delta) == "nil" then -- is nil
            delta = 1
        else -- not nil
            error(string.format(
                "IncrementAsync, delta is a {%s}, {nil|integer} expected",
                typeof(delta)
                ))
        end
    else -- is a number
        if math.floor(delta) ~= delta then -- not an integer
            error("IncrementAsync, delta is a number but is not an integer")
        end
    end

    data += delta
    return self:SetAsync(key, data, "PUT")
end

function Robase:BatchUpdateAsync(baseKey, callbacks, cache)
    assert(typeof(callbacks) == "table", ("Bad argument 2, table expected got %s"):format(typeof(callbacks)))

    local updated = { }

    for key, updateFunc in pairs(callbacks) do
        assert(typeof(updateFunc)=="function", ("Callbacks[%s] function expected got %s"):format(key, typeof(updateFunc)))

        local success, data
        if cache~=nil and cache[key] then
            data = cache[key]
            success = (data~=nil)
        else
            success, data = self:GetAsync(("%s/%s"):format(baseKey, key))
        end
        assert(data ~= nil or not success, "Something went wrong retrieving data, make sure a key exists for a callback function to perform on")

        updated[key] = updateFunc(data)
    end

    return self:SetAsync(baseKey, updated, "PATCH")
end

function Robase:orderByChild(orderBy)
    assert(not self._queryOption.shallow, ('Shallow cannot be used with any of the "filtering data" query parameters.'))

    local newQueryOption = deepcopy(self._queryOption)
    local deepcopyRobase = Robase.new(
        self._path,
        self._robaseService
    )    
    newQueryOption.orderBy = tostring(orderBy)
    deepcopyRobase._queryOption = newQueryOption

    return deepcopyRobase
end

function Robase:setShallow(shallow)
    assert(typeof(shallow) == "boolean", ("Bad argument 1, boolean expected got %s"):format(typeof(shallow)))
    assert(
        not self._queryOption.orderBy,
        ('shallow cannot be used with any of the "filtering data" query parameters.')
    )

    local newQueryOption = deepcopy(self._queryOption)
    local deepcopyRobase = Robase.new(
        self._path,
        self._robaseService
    )    
    newQueryOption.shallow = not not shallow
    deepcopyRobase._queryOption = newQueryOption

    return deepcopyRobase
end


function Robase:limitToLast(limitToLast)
    assert(not self._queryOption.shallow, ('Shallow cannot be used with any of the "filtering data" query parameters.'))
    assert(typeof(limitToLast) == "string", ("Bad argument 1, string expected got %s"):format(typeof(limitToLast)))

    local newQueryOption = deepcopy(self._queryOption)
    local deepcopyRobase = Robase.new(
        self._path,
        self._robaseService
    )    
    newQueryOption.limitToLast = tostring(limitToLast)
    deepcopyRobase._queryOption = newQueryOption

    return deepcopyRobase
end

function Robase:limitToFirst(limitToFirst)
    assert(
        not self._queryOption.shallow, 
        ('Shallow cannot be used with any of the "filtering data" query parameters.')
    )
    assert(typeof(limitToFirst) == "string", ("Bad argument 1, string expected got %s"):format(typeof(limitToFirst)))

    local newQueryOption = deepcopy(self._queryOption)
    local deepcopyRobase = Robase.new(
        self._path,
        self._robaseService
    )    
    newQueryOption.limitToFirst = tostring(limitToFirst)
    deepcopyRobase._queryOption = newQueryOption

    return deepcopyRobase
end

function Robase:startAt(startAt)
    assert(self._queryOption.shallow == false, ('Shallow cannot be used with any of the "filtering data" query parameters.'))
    assert(self._queryOption.orderBy, ('Range Queries require orderBy'))
    assert(typeof(startAt) == "string", ("Bad argument 1, string expected got %s"):format(typeof(startAt)))

    local newQueryOption = deepcopy(self._queryOption)
    local deepcopyRobase = Robase.new(
        self._path,
        self._robaseService
    )    
    newQueryOption.startAt = tostring(startAt)
    deepcopyRobase._queryOption = newQueryOption

    return deepcopyRobase
end

function Robase:endAt(endAt)
    assert(self._queryOption.shallow == false, ('Shallow cannot be used with any of the "filtering data" query parameters.'))
    assert(self._queryOption.orderBy, ('Range Queries require orderBy'))
    assert(typeof(endAt) == "string", ("Bad argument 1, string expected got %s"):format(typeof(endAt)))
    
    local newQueryOption = deepcopy(self._queryOption)
    local deepcopyRobase = Robase.new(
        self._path,
        self._robaseService
    )    
    newQueryOption.endAt = tostring(endAt)
    deepcopyRobase._queryOption = newQueryOption

    return deepcopyRobase
end

function Robase:equalTo(equalTo)
    assert(self._queryOption.shallow == false, ('Shallow cannot be used with any of the "filtering data" query parameters.'))
    assert(self._queryOption.orderBy, ('Range Queries require orderBy'))
    assert(typeof(equalTo) == "string", ("Bad argument 1, string expected got %s"):format(typeof(equalTo)))

    local newQueryOption = deepcopy(self._queryOption)
    local deepcopyRobase = Robase.new(
        self._path,
        self._robaseService
    )    
    newQueryOption.equalTo = tostring(equalTo)
    deepcopyRobase._queryOption = newQueryOption

    return deepcopyRobase
end

--[[function Robase:BatchUpdateAsync(baseKey, uploadKeyValues, uploadCallbacks, cache)
    local t1,t2 = typeof(uploadKeyValues), typeof(uploadCallbacks)
    assert(t1 == "table", "Bad argument 2, table expected got " .. t1)
    assert(t2 == "table", "Bad argument 3, table expected got " .. t2)
    t1,t2=nil,nil

    local updated = { }

    for key, value in pairs(uploadKeyValues) do
        assert(uploadCallbacks[key]~=nil, "BatchUpdateAsync: '"..key.."' does not have a callback function")
        assert(typeof(uploadCallbacks[key])=="function", "Callback is not a function")

        local success, data
        if cache~=nil and cache[key] then
            data = cache[key]
            success = (data~=nil)
        else
            success, data = self:GetAsync(string.format("%s/%s", baseKey, key))
        end

        local new = uploadCallbacks[key](data)
        updated[key] = new
    end

    return self:SetAsync(baseKey, updated, "PATCH")
end]]

return Robase