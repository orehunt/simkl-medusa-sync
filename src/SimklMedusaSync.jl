module SimklMedusaSync

using HTTP
using JSON
using Dates: now
using Base64

const redirect_uri = Ref("urn:ietf:wg:oauth:2.0:oob")
const simkl_oauth = "https://simkl.com/oauth/authorize"
const simkl_pin = "https://api.simkl.com/oauth/pin"
const simkl_all_items = "https://api.simkl.com/sync/all-items"

const cache_path = Ref(get(ENV, "XDG_CACHE_HOME", "$(ENV["HOME"])/.cache"))
const creds_path = Ref(joinpath(cache_path[], "simkl_creds.json"))
const items_path = Ref(joinpath(cache_path[], "simkl_items.json"))
const creds = IdDict{String, String}()
isfile(creds_path[]) && merge!(creds, JSON.parse(read(creds_path[], String)))
const access_token = Ref(get(creds, "access_token", ""))
const headers = []

@inline function tv_url(ids)
    if "imdb" ∈ keys(ids)
        "https://www.imdb.com/title/" * ids["imdb"]
    elseif "tvdbslug" ∈ keys(ids)
        "https://www.thetvdb.com/series/" * ids["tvdbslug"]
    elseif "anidb" ∈ keys(ids)
        "https://anidb.net/anime/" * ids["anidb"]
    else
        ""
    end
end

@inline function simkl_url(type, show::String)
    "https://simkl.com/" * type * "/" * show
end

function get_simkl_pin()
    try
        query = Dict("client_id" => creds["client_id"],
                 "redirect_uri" => redirect_uri[])
    catch KeyError
        throw("client_id or redirect_uri not found, make sure json config at $(creds_path[]) is valid.")
    end
    res = HTTP.request("GET", simkl_pin, headers; query)
    body = JSON.parse(String(res.body))
    body["user_code"], body["verification_url"]
end

function get_simkl_token(code)
    query = Dict("client_id" => creds["client_id"])
    res = HTTP.request("GET", joinpath(simkl_pin, code), headers; query)
    body = JSON.parse(String(res.body))
    get(body, "access_token", "")
end

function simkl_set_headers!()
    empty!(headers)
    push!(headers, "Content-Type" => "application/json")
    push!(headers, "Authorization" => "Bearer $(access_token[])")
    push!(headers, "simkl-api-key" => creds["client_id"])
end

@doc "Checks if an ACCESS_TOKEN key is present in the file pointed by CREDS_PATH. If not present initiate
a pin verification procedure."
function simkl_auth()
    token = ""
    if isempty(get(creds, "access_token", ""))
        code, url = get_simkl_pin()
        @info "Verify pin: $code at $url"
        sl = 1
        while true
            token = get_simkl_token(code)
            isempty(token) || break
            @info "token not yed found, sleeping for $sl..."
            sleep(sl)
            sl += 1
        end
        creds["code"] = code
        creds["access_token"] = token
        access_token[] = token
        write(creds_path[], JSON.json(creds))
        @info "Saved new access token to $(creds_path[])"
    else
        @info "Access token already available."
    end
    simkl_set_headers!()
end

function simkl_query_items(query ;type, status, backoff=0)
    sleep(backoff)
    simkl_set_headers!()
    items = nothing
    try
        res = HTTP.request("GET", joinpath(simkl_all_items, type, status), headers; query)
        items = JSON.parse(String(res.body))
    catch
        backoff =  (backoff + 1) * 2
        @warn "Simkl query failed, retrying after $backoff"
        items = simkl_query_items(query; type, status, backoff)
    end
    items
end


function simkl_fetch_all_items(type="", status=""; reset=false)
    date_from = reset ? "" : get(creds, "date_from", "")
    query = Dict()
    prev_items_dict = nothing
    isempty(date_from) || begin
	    query["date_from"] = date_from
        isfile(items_path[]) && begin
            prev_items_dict = JSON.parse(read(items_path[], String))
        end
    end
    items = simkl_query_items(query; type, status)
    items_dict = Dict()
    # convert the api response into a proper dict where each key is a show,
    # (instead of a vector)
    if !isnothing(items)
        for (k, d) in items
            ik = (k === "anime" || k === "shows") ? "show" : "movie"
            items_dict[k] = Dict(i[ik]["title"] => i for i in d)
        end
    end
    if isnothing(prev_items_dict)
        write(items_path[], JSON.json(items_dict))
        prev_items_dict = items_dict
    else
        if !isnothing(items) || "error" ∉ keys(items_dict)
            # merge shows,movies, and animes separately to not remove pre existing ones
            # since merge! overrides top level keys
            # NOTE: we also assume that items are never removed from simkl, because
            # merging overrides existing ones, but doesn't remove..., and since we don't
            # fetch the whole list all the times, we don't know which items would be removed
            # from simkl
            for (k, d) in prev_items_dict
                k ∈ keys(items_dict) && merge!(d, items_dict[k])
            end
            write(items_path[], JSON.json(prev_items_dict))
        end
    end
    creds["date_from"] = string(now())
    write(creds_path[], JSON.json(creds))
    prev_items_dict
end

function simkl_get_all_items(update=false; reset=false, kwargs...)
    first_time = !isfile(items_path[])
    reset = isnothing(reset) ? first_time : reset
    if update || first_time
        simkl_fetch_all_items(;reset, kwargs...)
    else
	    JSON.parse(read(items_path[], String))
    end
end

function simkl_get_shows(status="watching"; types = ["shows", "anime"])
    all_items = simkl_get_all_items()
    shows = []
    for tp in types
        for el in all_items[tp]
            if el["status"] === status
                push!(shows, el)
            end
        end
    end
    shows
end

function simkl_get_show_by_title(title; status="watching")
    shows = simkl_get_shows(status)
    for s in shows
        s["show"]["title"] === title && return s
    end
end

## MEDUSA ##

const medusa_url = Ref(get(ENV, "MEDUSA_URL", "http://localhost:8081"))
const medusa_token = Ref("")
const medusa_headers = []

function medusa_set_token()
    res = HTTP.request("POST", medusa_url[] * "/api/v2/authenticate")
    medusa_token[] = JSON.parse(String(res.body))["token"]
end

function medusa_set_headers!()
    empty!(medusa_headers)
    push!(medusa_headers, "Content-Type" => "application/json")
    push!(medusa_headers, "Authorization" => "Bearer $(medusa_token[])")
end

function medusa_auth()
    medusa_set_token()
    medusa_set_headers!()
end

@doc "ID should be a pair of for \"PROVIDER\" => ID "
function medusa_add_series(id::Pair;
                           # this quality means "all the 1080p version"
                           quality=Dict("allowed" => [32, 128, 512], "preferred" => []),
                           release=Dict("blacklist" => [], "whitelist" => []),
                           lists=["series"],
                           anime=false, scene=false,
                           # skip past episodes
                           status=5,
                           # want future episodes
                           status_after=3)
    body = Dict{String, Any}("id" => Dict(id))
    body["options"] = Dict("quality" => quality,
                           "anime" => anime,
                           "status" => status,
                           "statusAfter" => status_after,
                           "rootDir" => "/data/shows",
                           "subtitles" => true,
                           "scene" => scene,
                           "seasonFolders" => true,
                           "showLists" => lists,
                           "release" => release,
                           "lang" => "en")
    HTTP.request("POST", medusa_url[] * "/api/v2/series", medusa_headers, JSON.json(body)) |>
        x -> JSON.parse(String(x.body))
end

function medusa_remove_series(slug)
    @info "removing $(slug) from Medusa."
    HTTP.request("DELETE", medusa_url[] * "/api/v2/series/" * slug, medusa_headers)
end

@doc "Fetch medusa series (max 1000)."
function medusa_get_shows(limit=1000)
    query = Dict("limit" => limit)
    HTTP.request("GET", medusa_url[] * "/api/v2/series", medusa_headers; query) |>
        x -> JSON.parse(String(x.body))
end

function get_show_id(show)
    ids = show["ids"]
    k = keys(show["ids"])
    # medusa doesn't want imdb as indexer
    # "imdb" ∈ k && return "imdb" => ids["imdb"]
    "tvdb" ∈ k && return "tvdb" => ids["tvdb"]
    "tmdb" ∈ k && return "tmdb" => ids["tmdb"]
    "anidb" ∈ k && return "anidb" => ids["anidb"]
    "mal" ∈ k && return "mal" => ids["mal"]
    @info "No valid id found for $(show["title"])"
    nothing
end

@doc "Add all watching series to medusa."
function simkl_to_medusa()
	watching = simkl_get_shows("watching")
    id = ""
    added = 0
    for item in watching
        try
            id = get_show_id(item["show"])
            if !isnothing(id)
                res = medusa_add_series(id; anime=(id[1] ∈ Set(("anidb", "mal"))))
                added += 1
                @debug "Adding $(item["show"]["title"]) to Medusa."
            end
        catch error
            @debug hasfield(error, :response) || error
            res = JSON.parse(String(error.response.body))
            get(res, "error", "") === "Series already exist added" || @info res, id, item["show"]["ids"]
        end
    end
    @info "Added $added shows to medusa."
end

import Base.convert
convert(::Type{Pair{String, String}}, val::Pair{String, Any}) = val[1] => string(val[2])

@doc "Remove all medusa series that are not in simkl the watching list."
function medusa_from_simkl()
    simkl_shows = simkl_get_shows("watching")
    simkl_ids = Set([hash(convert(Pair{String, String}, idpair)) for show in simkl_shows for idpair in show["show"]["ids"]])
    @assert !isempty(simkl_ids)
    medusa_shows = medusa_get_shows()
    "error" ∈ medusa_shows && begin
        medusa_auth()
        medusa_shows = medusa_get_shows()
    end
    allowed = Set(["tvdb", "anidb", "tmdb", "imdb"])
    for show in medusa_shows
        ids = show["id"]
        present = false
        for id in ids
            if hash(convert(Pair{String, String}, id)) ∈ simkl_ids
                present = true
                break
            end
        end
        # !present && (display("gotta remove: " * show["title"]); display(show["id"]))
        !present && (medusa_remove_series(show["id"]["slug"]))
    end
end

function medusa_remove_duplicates()
    medusa_shows = medusa_get_shows()
    processed = Set{String}()
    for show in medusa_shows
        title = show["title"]
        if title ∉ processed
            push!(processed, title)
        else
            medusa_remove_series(show["id"]["slug"])
        end
    end
end

function run()
    # ensure dirs exist
    for d in (cache_path, creds_path, items_path)
        mkpath(dirname(d[]))
    end
    simkl_auth()
    medusa_auth()

    while true
        @info "Updating symkl list..."
        simkl_get_all_items(true)
        # first remove non present series
        medusa_from_simkl()
        # then add new series from simkl
        simkl_to_medusa()
        # process once every 8 hours by default
        sleep(get(ENV, "SYNC_SLEEP", 60 * 60 * 8))
    end
end

precompile(run, ())

end
