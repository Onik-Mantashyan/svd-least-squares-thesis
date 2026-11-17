using HTTP
using JSON
using LinearAlgebra

const SRC_DIR = normpath(joinpath(@__DIR__, "..", "src"))
# Կեշավորում ենք ըստ ֆայլի անվան՝ (mtime, Module)
const PLUGINS = Dict{String, Tuple{Float64, Module}}()

mat_to_rows(M::AbstractMatrix) = [Float64.(collect(M[i, :])) for i in 1:size(M, 1)]
parse_matrix(rows) = reduce(vcat, [Float64.(r)' for r in rows])

function json_response(status::Int, data)
    headers = ["Content-Type" => "application/json; charset=utf-8"]
    return HTTP.Response(status, headers, JSON.json(data))
end

# Սկանավորում է src/ թղթապանակը և համաժամեցնում մոդուլները
function sync_plugins!()
    isdir(SRC_DIR) || return String[]
    files = sort(filter(f -> endswith(f, ".jl"), readdir(SRC_DIR)))

    # Հեռացնել այն ֆայլերը, որոնք այլևս չկան src/-ում
    for fname in collect(keys(PLUGINS))
        if !(fname in files)
            delete!(PLUGINS, fname)
        end
    end

    # Բեռնել նոր կամ փոփոխված ֆայլերը առանձին մոդուլների մեջ (անունների կոնֆլիկտից խուսափելու համար)
    for fname in files
        path = joinpath(SRC_DIR, fname)
        mt = mtime(path)
        if !haskey(PLUGINS, fname) || PLUGINS[fname][1] != mt
            mod = Module(gensym(:Plugin))
            Core.eval(mod, :(using LinearAlgebra))
            Base.include(mod, path)
            PLUGINS[fname] = (mt, mod)
        end
    end
    return files
end

# Ավտոմատ դաշտի տիպի կռահում՝ ըստ արգումենտի անվան
function guess_field(arg::String)
    low = lowercase(arg)
    if low in ("a", "b_mat", "mat", "matrix") || occursin("mat", low)
        return Dict("name" => arg, "label" => "Մատրից $arg", "type" => "matrix", "default" => "1 2\n3 4")
    elseif low in ("x", "y", "v", "w", "vec", "coeffs") || occursin("vec", low)
        return Dict("name" => arg, "label" => "Վեկտոր $arg (ստորակետով)", "type" => "vector", "default" => "1, 2, 3")
    else
        return Dict("name" => arg, "label" => "Պարամետր $arg", "type" => "number", "default" => "2")
    end
end

# Ավտոմատ UI սխեմա, եթե ֆայլը չունի իր web_spec()-ը
function auto_spec(fname::String, mod::Module)
    actions = Any[]
    for s in names(mod; all=false, imported=false)
        s == nameof(mod) && continue
        val = getfield(mod, s)
        val isa Function || continue

        m = first(methods(val))
        arg_syms = try
            raw = Base.method_argnames(m)
            raw[2:min(m.nargs, length(raw))]
        catch
            [Symbol("arg", i) for i in 1:(m.nargs - 1)]
        end

        push!(actions, Dict(
            "id" => String(s),
            "title" => String(s),
            "fields" => [guess_field(String(a)) for a in arg_syms]
        ))
    end
    return Dict(
        "id" => fname,
        "title" => replace(fname, ".jl" => ""),
        "mode" => "auto",
        "actions" => actions
    )
end

function parse_auto_arg(field_type::String, raw)
    if field_type == "matrix"
        return parse_matrix(raw)
    elseif field_type == "vector"
        return Float64.(raw)
    else
        v = Float64(raw)
        return isinteger(v) ? Int(v) : v
    end
end

function format_auto_output(res)
    items = res isa Tuple ? collect(res) : [res]
    texts = String[]
    matrices = Any[]

    for (idx, item) in enumerate(items)
        if item isa AbstractMatrix
            push!(matrices, Dict("title" => "Արդյունք #$idx", "data" => mat_to_rows(item)))
        elseif item isa AbstractVector
            push!(texts, "Վեկտոր #$idx = [" * join(round.(Float64.(item); digits=5), ", ") * "]")
        elseif item isa Number
            push!(texts, "Արժեք #$idx = " * string(round(Float64(item); digits=5)))
        else
            push!(texts, "Արդյունք #$idx = " * string(item))
        end
    end

    plots = Any[]
    if !isempty(matrices)
        push!(plots, Dict("type" => "heatmaps", "title" => "Ստացված մատրիցներ", "matrices" => matrices))
    end
    return Dict("text" => isempty(texts) ? "Հաշվարկը կատարված է" : join(texts, "\n"), "plots" => plots)
end

function handle_request(req::HTTP.Request)
    if req.method == "GET" && req.target == "/"
        html = read(joinpath(@__DIR__, "index.html"), String)
        return HTTP.Response(200, ["Content-Type" => "text/html; charset=utf-8"], html)
    end

    try
        if req.method == "GET" && req.target == "/api/modules"
            files = sync_plugins!()
            modules = Any[]
            for fname in files
                _, mod = PLUGINS[fname]
                if isdefined(mod, :web_spec)
                    spec = Base.invokelatest(getfield(mod, :web_spec))
                    spec["id"] = fname
                    spec["mode"] = "plugin"
                    push!(modules, spec)
                else
                    push!(modules, auto_spec(fname, mod))
                end
            end
            sort!(modules; by = m -> (get(m, "order", 999), String(m["id"])))
            return json_response(200, Dict("modules" => modules))

        elseif req.method == "POST" && req.target == "/api/run"
            sync_plugins!()
            body = JSON.parse(String(req.body))
            fname = String(body["file"])
            action = String(body["action"])
            params = get(body, "params", Dict{String, Any}())

            haskey(PLUGINS, fname) || error("Մոդուլը չի գտնվել src/-ում: $fname")
            _, mod = PLUGINS[fname]

            if isdefined(mod, :web_run)
                out = Base.invokelatest(getfield(mod, :web_run), action, params)
                return json_response(200, out)
            else
                # Ավտոմատ կանչ
                spec = auto_spec(fname, mod)
                act_idx = findfirst(a -> a["id"] == action, spec["actions"])
                act_idx === nothing && error("Ֆունկցիան չի գտնվել: $action")
                fields = spec["actions"][act_idx]["fields"]
                args = [parse_auto_arg(f["type"], params[f["name"]]) for f in fields]
                fn = getfield(mod, Symbol(action))
                res = Base.invokelatest(fn, args...)
                return json_response(200, format_auto_output(res))
            end
        end

        return json_response(404, Dict("error" => "Endpoint not found"))
    catch e
        return json_response(400, Dict("error" => sprint(showerror, e)))
    end
end

println("==================================================")
println(" Dynamic Visual Platform is running!")
println(" Open in browser: http://127.0.0.1:8080")
println("==================================================")

HTTP.serve(handle_request, "127.0.0.1", 8080)