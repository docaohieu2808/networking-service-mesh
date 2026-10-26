# OpenResty image for the l-max lab: stock OpenResty + lua-resty-jwt (via opm)
# + the Lua modules under ./lua. The config itself is mounted at run time.
FROM openresty/openresty:1.31.1.1-alpine-fat
RUN opm get cdbattags/lua-resty-jwt=0.3.2
COPY lua/ /etc/nginx/lua/
