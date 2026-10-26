-- JWT verification and per-user rate limiting for the l-max lab.
-- Used from nginx.conf like:
--     access_by_lua_block { require("auth").require_jwt() }
-- Every protected location calls it explicitly. An access_by_lua_block inside a
-- location REPLACES any server-level one (it is not additive), so a shared
-- function called from each location is the safe pattern.

local jwt   = require "resty.jwt"
local cjson = require "cjson.safe"

local _M = {}

-- The secret comes from the environment. nginx wipes the worker environment
-- unless `env JWT_SECRET;` is declared in the main context of nginx.conf.
-- There is NO fallback value: a missing/short secret fails closed with 500.
local MIN_SECRET_BYTES = 32
local secret = os.getenv("JWT_SECRET")

local function deny(status, message)
    ngx.status = status
    ngx.header["Content-Type"] = "application/json"
    ngx.say(cjson.encode({ error = message }))
    return ngx.exit(status)
end

function _M.require_jwt()
    if not secret or #secret < MIN_SECRET_BYTES then
        ngx.log(ngx.ERR, "JWT_SECRET missing or shorter than ", MIN_SECRET_BYTES, " bytes")
        return deny(500, "server misconfigured")
    end

    -- Never trust identity headers coming from the client.
    ngx.req.clear_header("X-User-ID")
    ngx.req.clear_header("X-User-Role")

    local auth_header = ngx.req.get_headers()["Authorization"]
    local token = type(auth_header) == "string" and auth_header:match("^Bearer ([%w%-_%.]+)$")
    if not token then
        return deny(401, "missing or malformed bearer token")
    end

    local dict   = ngx.shared.jwt_cache
    local cached = dict:get(token)
    local claims
    if cached then
        claims = cjson.decode(cached)
    else
        local verified = jwt:verify(secret, token)
        if not verified.verified then
            return deny(401, "invalid token")
        end
        -- Pin the algorithm: only HS256 is accepted ("none" or RS256 confusion is not).
        if not verified.header or verified.header.alg ~= "HS256" then
            return deny(401, "invalid token")
        end
        claims = verified.payload
        -- exp is mandatory; lua-resty-jwt validates it when present.
        if type(claims.exp) ~= "number" or type(claims.sub) ~= "string" then
            return deny(401, "token needs sub and exp claims")
        end
        local ttl = math.min(claims.exp - ngx.time(), 300)
        if ttl <= 0 then
            return deny(401, "token expired")
        end
        dict:set(token, cjson.encode(claims), ttl)
    end

    ngx.req.set_header("X-User-ID", claims.sub)
    ngx.req.set_header("X-User-Role", type(claims.role) == "string" and claims.role or "user")
    -- Remembered for rate limiting: this value is verified, unlike request headers.
    ngx.ctx.user_id = claims.sub
end

-- Fixed-window counter per verified user (call after require_jwt).
function _M.rate_limit(limit, window)
    local dict  = ngx.shared.rate_limit
    local key   = "rl:" .. (ngx.ctx.user_id or ngx.var.remote_addr)
    local count = dict:incr(key, 1, 0, window)
    if not count then
        ngx.log(ngx.ERR, "rate_limit dict full")
        return deny(503, "rate limiter unavailable")
    end
    ngx.header["X-RateLimit-Limit"]     = limit
    ngx.header["X-RateLimit-Remaining"] = math.max(0, limit - count)
    if count > limit then
        ngx.header["Retry-After"] = window
        return deny(429, "rate limit exceeded")
    end
end

return _M
