module KrakenAPI

using Formatting
import Requests: get, post, statuscode, json
import Nettle: digest

#API key import functions
export init_api_key, load_api_key
#Misc derived functions
export set_decimals
#Misc public functions
export kraken_time
#Public functions to query market data
export assets, asset_pairs, ticker, ohlc, order_book, trades, spread
#Private functions to query user data
export private_balance, private_trade_balance, private_open_orders
export private_closed_orders, private_query_orders, private_trades_history
export private_query_trades, private_open_positions, private_ledgers
export private_query_ledgers, private_trade_volume
#Private functions to trade
export buy_market, sell_market, buy_limit, sell_limit, order_arb, cancel_order

global api_key
global api_secret
global api_version = 0
global price_decimals = Dict{String}{Int64}()
global lot_decimals = Dict{String}{Int64}()
global query_timeout = 10
global base_uri = "https://api.kraken.com"

function get_nonce()
"""Continuously incrementing number required for private queries

    :returns: local unix time in ms as a string

"""
    return string(Int64(floor(time()*1000)))
end

function post_string(data::Dict)
""" Returns the string representation of the POST data
    Needed for cryptographic signature functions

    :param data: dictionary of POST data
    :type data: Dict object
    :returns: String object

"""
    s = ""
    for i in keys(data)
        s *= i * "=" * data[i] * "&"
    end

    return s[1:end-1]       #Don't return last trailing &

end

function query(func::String, data::Dict = Dict(), header::Dict = Dict())
""" Low level function to query POST data
    :param func: API function to query
    :type func: String"
    :param data: optional, data to pass to the POST method
    :type data: Dict object
    :param header: optional, HTTP header to pass to the POST method
    :type header: Dict object
    :returns: ["results"] key of the JSON returned or rethrows the error

"""
    url = base_uri * "/" * string(api_version) * func

    res = ""

    try
        res = post(url, data = data, headers = header, timeout = query_timeout)
    catch e
        rethrow(e)
    end

    j = []

    try
        j = json(res)
    catch e
        rethrow(e)
    end

    if j["error"] != []
        error("JSON error: "*string(j["error"][1]))
    else
        return j["result"]
    end

end

function sign_msg(func::String, postdata::Dict, nonce::String)
"""Sign the message for private functions

    See https://www.kraken.com/en-us/help/api#general-usage

    :param postdata: POST data to be sent
    :type postdata: Dict object
    :returns: signature string to be added to HTTP header

"""
    urlpath = "/" * string(api_version) * func
    msg = urlpath * transcode(String, digest("sha256", nonce*post_string(postdata)))
    b = base64decode(api_secret)
    sig = base64encode(transcode(String, digest("sha512", b, msg)))
    return sig
end

function init_api_key(api_k::String, api_s::String)
""" Sets global api_key and api_secret from parameter list

    :param api_k: Kraken API key
    :type api_k: String
    :param api_s: Kraken API secret, a.k.a. private key
    :type api_s: String

"""
    global api_key = api_k
    global api_secret = api_s
end

function load_api_key(filen::String)
""" Loads api_key and api_secret from a file

    Also sets global parameters. Expected file format is
    api_key and api_secret in two lines

    :param filen: filename
    :type filen: String

"""

    vals = []

    try
        vals = readlines(filen)
    catch e
        rethrow(e)
    end

    if size(vals)[1] == 2
        init_api_key(strip(vals[1]), strip(vals[2]))
        return
    else
        error("Invalid file format, two lines are expected.")
    end
end

function set_decimals()
""" Sets the granularity of exchange rate and order size for available pairs
    This function calls asset_pairs, and fills in global price_decimals and lot_decimals
    The roundings then can be used in the trading functions

"""
    global price_decimals
    global lot_decimals
    res = asset_pairs()
    for i in keys(res)
        price_decimals[i] = res[i]["pair_decimals"]
        lot_decimals[i] = res[i]["lot_decimals"]
    end

end

function kraken_time()
""" Returns Kraken server unix time

    :returns: unix time of the Kraken server in seconds as Int64

"""

    return query("/public/Time")["unixtime"]
end

function assets()
""" Returns asset information

    See https://www.kraken.com/en-us/help/api#get-asset-info

        :returns: Dict object

"""

    return query("/public/Assets")
end

function asset_pairs()
""" Returns asset pair information

    See https://www.kraken.com/en-us/help/api#get-tradable-pairs

        :returns: Dict object

"""

    return query("/public/AssetPairs")
end

function ticker(pair::String)
""" Returns ticker information for the given asset pair

    See https://www.kraken.com/en-us/help/api#get-ticker-info

    :param pair: Asset pair, e.g. XXBTZEUR
    :type pair: String
    :returns: Dict object

"""

    return query("/public/Ticker", Dict("pair" => pair))[pair]
end

function ohlc(pair::String; interval::Int64=1, since::Int64=-1)
""" Returns OHLC information for the given asset pair at the specified interval

    See https://www.kraken.com/en-us/help/api#get-ohlc-data

    :param pair: Asset pair, e.g. XXBTZEUR
    :type pair: String
    :param interval: time interval in minutes, can be 1 (default), 5, 15, 30, 60, 240, 1440, 10080, 21600
    :type interval: Int64
    :param since: time identifier. If provided, only queries for newer data.
    :type since: Int64
    :returns: Array object and new time identifier as Int64

"""
    data  = (since == -1 ?
     Dict("pair" => pair, "interval" => string(interval)) :
     Dict("pair" => pair, "interval" => string(interval), "since" => string(since)))
    res = query("/public/OHLC", data)
    return res[pair], res["last"]
end

function order_book(pair::String; count::Int64=-1)
""" Returns order book for the given asset pair

    See https://www.kraken.com/en-us/help/api#get-order-book

    :param pair: Asset pair, e.g. XXBTZEUR
    :type pair: String
    :param count: maximum number of asks and bids, values are capped at 500
    :type count: Int64
    :returns: Array object for asks and Array object for bids

"""
    data = (count == -1 ?
     Dict("pair" => pair) :
     Dict("pair" => pair, "count" => string(count)))
    res = query("/public/Depth", data)
    return res[pair]["asks"], res[pair]["bids"]
end

function trades(pair::String; since::Int64=-1)
""" Returns recent trades for the given asset pair

    See https://www.kraken.com/en-us/help/api#get-recent-trades

    :param pair: Asset pair, e.g. XXBTZEUR
    :type pair: String
    :param since: time identifier. If provided, only queries for newer data.
    :type since: Int64
    :returns: Array object with trade data and new time identifier as Int64

"""
    data = (since == -1 ?
     Dict("pair" => pair) :
     Dict("pair" => pair, "since" => string(since)))
     res = query("/public/Trades", data)
     return res[pair], parse(res["last"])
end

function spread(pair::String; since::Int64=-1)
""" Returns recent spread data for the given asset pair

    See https://www.kraken.com/en-us/help/api#get-recent-spread-data

    :param pair: Asset pair, e.g. XXBTZEUR
    :type pair: String
    :param since: time identifier. If provided, only queries for newer data.
    :type since: Int64
    :returns: Array object with trade data and new time identifier as Int64

"""
    data = (since == -1 ?
     Dict("pair" => pair) :
     Dict("pair" => pair, "since" => string(since)))
     res = query("/public/Spread", data)
     return res[pair], res["last"]
end

function private_balance()
""" Queries the user balance.

    See https://www.kraken.com/en-us/help/api#private-user-data
    Note that API key and secret have to be imported before calling this function

    :returns: Dict object: keys are asset names, values are balance.

"""

    func = "/private/Balance"
    nonce = get_nonce()
    postdata = Dict("nonce" => nonce)
    sig = sign_msg(func, postdata, nonce)
    headerdata = Dict("API-Key" => api_key, "API-Sign" => sig)

    return query(func, postdata, headerdata)

end

function private_trade_balance(;asset::String="")
""" Queries the user trade balance.

    See https://www.kraken.com/en-us/help/api#get-trade-balance
    Note that API key and secret have to be imported before calling this function
    It seems that optional argument asset class is not used, hence it is omitted here

    :param asset: Base asset name, e.g. ZEUR, default is ZUSD
    :type asset: String

    :returns: Dict object, see the keys in the link above

"""

    func = "/private/TradeBalance"
    nonce = get_nonce()
    postdata = Dict("nonce" => nonce, "asset" => asset)
    sig = sign_msg(func, postdata, nonce)
    headerdata = Dict("API-Key" => api_key, "API-Sign" => sig)

    return query(func, postdata, headerdata)

end

function private_open_orders(;trades::Bool=false, userref::Int32=Int32(0))
""" Queries the open orders of the user.

    See https://www.kraken.com/en-us/help/api#get-open-orders
    Note that API key and secret have to be imported before calling this function

    :param trades: include trades in result
    :type trades: Bool
    :param userref: only return data for given user reference (optionally set by trade order)
    :type userref: Int32

    :returns: Dict object, see the keys in the link above.

"""

    func = "/private/OpenOrders"
    nonce = get_nonce()
    postdata = Dict("nonce" => nonce, "trades" => trades?"true":"false")
    if userref != 0
        postdata["userref"] = string(userref)
    end
    sig = sign_msg(func, postdata, nonce)
    headerdata = Dict("API-Key" => api_key, "API-Sign" => sig)

    return query(func, postdata, headerdata)

end

function private_closed_orders(;trades::Bool=false, userref::Int32=Int32(0),
    start_time::Int64=-1, end_time::Int64=-1)
""" Queries the closed orders of the user.

    See https://www.kraken.com/en-us/help/api#get-closed-orders
    Note that API key and secret have to be imported before calling this function

    :param trades: include trades in result
    :type trades: Bool
    :param userref: only return data for given user reference (optionally set by trade order)
    :type userref: Int32
    :param start_time: beginning of time range of query (unix time, -1 for no limit)
    :type start_time: Int64
    :param end_time: end of time range of query (unix time, -1 for no limit)
    :type end_time: Int64
    :returns: Dict object, key "closed" contains the Dict of closed orders,
                            key "count" contains the number of the closed orders.

"""

    func = "/private/ClosedOrders"
    nonce = get_nonce()
    postdata = Dict("nonce" => nonce)
    #add optional parameters
    postdata["trades"] = trades?"true":"false"
    if userref  != 0
        postdata["userref"] = string(userref)
    end
    if start_time != -1
        postdata["start"] = string(start_time)
    end
    if end_time != -1
        postdata["end"] = string(end_time)
    end
    sig = sign_msg(func, postdata, nonce)
    headerdata = Dict("API-Key" => api_key, "API-Sign" => sig)

    return query(func, postdata, headerdata)

end

function private_query_orders(;trades::Bool=false, userref::Int32=Int32(0), txid::String="")
""" Queries order information for each txid provided.

    See https://www.kraken.com/en-us/help/api#query-orders-info
    Note that API key and secret have to be imported before calling this function

    :param trades: include trades in result
    :type trades: Bool
    :param userref: only return data for given user reference (optionally set by trade order)
    :type userref: Int32
    :param txid: comma separated list of a max. of 20 order txid values
    :type txid: String
    :returns: Dict object, with supplied txid as key values.

"""

func = "/private/QueryOrders"
nonce = get_nonce()
postdata = Dict("nonce" => nonce, "txid" => txid)
#add optional parameters
postdata["trades"] = trades?"true":"false"
if userref  != 0
    postdata["userref"] = string(userref)
end
sig = sign_msg(func, postdata, nonce)
headerdata = Dict("API-Key" => api_key, "API-Sign" => sig)

return query(func, postdata, headerdata)

end

function private_trades_history()
""" Queries trade history of the user.

    See https://www.kraken.com/en-us/help/api#get-trades-history
    Note that API key and secret have to be imported before calling this function
    TODO: implement optional parameters

    :returns: Dict object, key "trades" contains the Dict of trades,
                            key "count" contains the number of trades.
"""

func = "/private/TradesHistory"
nonce = get_nonce()
postdata = Dict("nonce" => nonce)
sig = sign_msg(func, postdata, nonce)
headerdata = Dict("API-Key" => api_key, "API-Sign" => sig)

return query(func, postdata, headerdata)

end

function private_query_trades(;trades::Bool=false, txid::String="")
""" Queries order information for each txid provided.

    See https://www.kraken.com/en-us/help/api#query-trades-info
    Note that API key and secret have to be imported before calling this function

    :param trades: include trades in result
    :type trades: Bool
    :param txid: comma separated list of a max. of 20 order txid values
    :type txid: String
    :returns: Dict object, with supplied txid as key values.

"""

func = "/private/QueryTrades"
nonce = get_nonce()
postdata = Dict("nonce" => nonce, "txid" => txid)
#add optional parameters
postdata["trades"] = trades?"true":"false"
sig = sign_msg(func, postdata, nonce)
headerdata = Dict("API-Key" => api_key, "API-Sign" => sig)

return query(func, postdata, headerdata)

end

function private_open_positions(;txid::String="", docalcs::Bool=false)
""" Queries open positions for each txid provided.

    See https://www.kraken.com/en-us/help/api#get-open-positions
    Note that API key and secret have to be imported before calling this function

    :param txid: comma separated list of txid values
    :type txid: String
    :param docalcs: include gain-loss calculation, default is false
    :type docalcs: Bool
    :returns: Dict object, with supplied txid as key values.

"""

func = "/private/OpenPositions"
nonce = get_nonce()
postdata = Dict("nonce" => nonce, "txid" => txid,
    "docalcs" => docalcs?"true":"false")
sig = sign_msg(func, postdata, nonce)
headerdata = Dict("API-Key" => api_key, "API-Sign" => sig)

return query(func, postdata, headerdata)

end

function private_ledgers()
""" Queries trade history of the user.

    See https://www.kraken.com/en-us/help/api#get-ledgers-info
    Note that API key and secret have to be imported before calling this function
    TODO: implement optional parameters

    :returns: Dict object, key "ledger" contains the Dict of ledger entries,
                            key "count" contains the number of ledger entries.

"""

    func = "/private/Ledgers"
    nonce = get_nonce()
    postdata = Dict("nonce" => nonce)
    sig = sign_msg(func, postdata, nonce)
    headerdata = Dict("API-Key" => api_key, "API-Sign" => sig)

    return query(func, postdata, headerdata)

end

function private_query_ledgers(;id::String="")
""" Queries ledger info for each id supplied.

    See https://www.kraken.com/en-us/help/api#query-ledgers
    Note that API key and secret have to be imported before calling this function
    :param id: comma separated list of a max. of 20 ledge id values
    :type id: String

    :returns: Dict object, with the ledger id as key values.

"""

    func = "/private/QueryLedgers"
    nonce = get_nonce()
    postdata = Dict("nonce" => nonce, "id" => id)
    sig = sign_msg(func, postdata, nonce)
    headerdata = Dict("API-Key" => api_key, "API-Sign" => sig)

    return query(func, postdata, headerdata)

end

function private_trade_volume()
""" Queries volume of trading of the user.

    See https://www.kraken.com/en-us/help/api#get-trade-volume
    Note that API key and secret have to be imported before calling this function
    TODO: implement optional parameters

    :returns: Dict object, with the ledger id as key values.

"""

    func = "/private/TradeVolume"
    nonce = get_nonce()
    postdata = Dict("nonce" => nonce)
    sig = sign_msg(func, postdata, nonce)
    headerdata = Dict("API-Key" => api_key, "API-Sign" => sig)

    return query(func, postdata, headerdata)

end

function buy_market(;pair::String="", volume::Float64=0, userref::Int32=Int32(0))
""" Simple buy order at market price

    See https://www.kraken.com/en-us/help/api#private-user-trading
    Note that API key and secret have to be imported before calling this function

    :param pair: Asset pair to trade, e.g. XXBTZEUR
    :type pair: String
    :param volume: amount to trade
    :type volume: Float64
    :param userref: set reference for trade queries, optional
    :type userref: Int32

    :returns: Dict object, "descr" => order description info
                            "txid" => order id

"""

func = "/private/AddOrder"
nonce = get_nonce()
postdata = Dict("nonce" => nonce, "pair" => pair, "type" => "buy",
 "ordertype" => "market",
 "volume" => format(volume, precision = Int(lot_decimals[pair])))
#add optional parameters
if userref != 0
    postdata["userref"] = string(userref)
end

sig = sign_msg(func, postdata, nonce)
headerdata = Dict("API-Key" => api_key, "API-Sign" => sig)

return query(func, postdata, headerdata)

end

function sell_market(;pair::String="", volume::Float64=0, userref::Int32=Int32(0))
""" Simple sell order at market price

    See https://www.kraken.com/en-us/help/api#private-user-trading
    Note that API key and secret have to be imported before calling this function

    :param pair: Asset pair to trade, e.g. XXBTZEUR
    :type pair: String
    :param volume: amount to trade
    :type volume: Float64
    :param userref: set reference for trade queries, optional
    :type userref: Int32

    :returns: Dict object, "descr" => order description info
                            "txid" => order id

"""

func = "/private/AddOrder"
nonce = get_nonce()
postdata = Dict("nonce" => nonce, "pair" => pair, "type" => "sell",
 "ordertype" => "market",
 "volume" => format(volume, precision = Int(lot_decimals[pair])))
#add optional parameters
if userref != 0
    postdata["userref"] = string(userref)
end

sig = sign_msg(func, postdata, nonce)
headerdata = Dict("API-Key" => api_key, "API-Sign" => sig)

return query(func, postdata, headerdata)

end

function buy_limit(;pair::String="", volume::Float64=0, price::Float64=0, userref::Int32=Int32(0))
""" Simple buy order at provided limit price

    See https://www.kraken.com/en-us/help/api#private-user-trading
    Note that API key and secret have to be imported before calling this function

    :param pair: Asset pair to trade, e.g. XXBTZEUR
    :type pair: String
    :param volume: amount to trade
    :type volume: Float64
    :param price: limit price
    :type price: Float64
    :param userref: set reference for trade queries, optional
    :type userref: Int32

    :returns: Dict object, "descr" => order description info
                            "txid" => order id

"""

func = "/private/AddOrder"
nonce = get_nonce()
postdata = Dict("nonce" => nonce, "pair" => pair, "type" => "buy",
 "ordertype" => "limit",
 "volume" => format(volume, precision = Int(lot_decimals[pair])),
 "price" => format(price, precision = Int(price_decimals[pair])))
#add optional parameters
if userref != 0
    postdata["userref"] = string(userref)
end

sig = sign_msg(func, postdata, nonce)
headerdata = Dict("API-Key" => api_key, "API-Sign" => sig)

return query(func, postdata, headerdata)

end

function sell_limit(;pair::String="", volume::Float64=0, price::Float64=0, userref::Int32=Int32(0))
""" Simple sell order at provided limit price

    See https://www.kraken.com/en-us/help/api#private-user-trading
    Note that API key and secret have to be imported before calling this function

    :param pair: Asset pair to trade, e.g. XXBTZEUR
    :type pair: String
    :param volume: amount to trade
    :type volume: Float64
    :param price: limit price
    :type price: Float64
    :param userref: set reference for trade queries, optional
    :type userref: Int32

    :returns: Dict object, "descr" => order description info
                            "txid" => order id

"""

func = "/private/AddOrder"
nonce = get_nonce()
postdata = Dict("nonce" => nonce, "pair" => pair, "type" => "sell",
 "ordertype" => "limit",
 "volume" => format(volume, precision = Int(lot_decimals[pair])),
 "price" => format(price, precision = Int(price_decimals[pair])))
#add optional parameters
if userref != 0
    postdata["userref"] = string(userref)
end

sig = sign_msg(func, postdata, nonce)
headerdata = Dict("API-Key" => api_key, "API-Sign" => sig)

return query(func, postdata, headerdata)

end

function order_arb(;pair::String="", order::String="", volume::Float64=0, ordertype::String="", args::Dict=Dict())
""" Advanced order, optional arguments are passed directly

        See https://www.kraken.com/en-us/help/api#private-user-trading
        Note that API key and secret have to be imported before calling this function
        Note that advanced order types (e.g. stop loss) are currently disabled

        :param pair: Asset pair to trade, e.g. XXBTZEUR
        :type pair: String
        :param order: type of order: "buy" or "sell"
        :type order: String
        :param volume: amount to trade
        :type volume: Float64
        :param ordertype: type of order, e.g. "market", "limit", "stop-loss"
        :type ordertype: String
        :param args: rest of the parameters, passed as a dictionary
        :type args: Dict

        :returns: Dict object, "descr" => order description info
                                "txid" => order id
"""

func = "/private/AddOrder"
nonce = get_nonce()
postdata = Dict("nonce" => nonce, "pair" => pair, "type" => order,
 "ordertype" => ordertype,
 "volume" => format(volume, precision = Int(lot_decimals[pair])))
#add optional parameters
merge!(postdata,args)

sig = sign_msg(func, postdata, nonce)
headerdata = Dict("API-Key" => api_key, "API-Sign" => sig)

return query(func, postdata, headerdata)


end

function cancel_order(;txid::String="")
""" Cancel order identified by the txid string

    See https://www.kraken.com/en-us/help/api#private-user-trading
    Note that API key and secret have to be imported before calling this function

    :param txid: Order id to cancel
    :type txid: String

    :returns: Dict object, "count" => number of orders cancelled
                            "pending" => cancellation pending

    """

    func = "/private/CancelOrder"
    nonce = get_nonce()
    postdata = Dict("nonce" => nonce, "txid" => txid)

    sig = sign_msg(func, postdata, nonce)
    headerdata = Dict("API-Key" => api_key, "API-Sign" => sig)

    return query(func, postdata, headerdata)

end

end
