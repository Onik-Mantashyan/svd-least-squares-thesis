using LinearAlgebra
using Printf

function linear_least_squares(x::AbstractVector{<:Real}, y::AbstractVector{<:Real})
    n = length(x)
    @assert n == length(y) "x and y must have the same length"
    @assert n >= 3 "At least 3 data points are required"

    sum_x = sum(x)
    sum_y = sum(y)
    sum_x2 = sum(x .^ 2)
    sum_xy = sum(x .* y)

    delta = sum_x^2 - n * sum_x2
    @assert delta != 0 "Determinant is zero; cannot solve uniquely"

    k = (sum_x * sum_y - n * sum_xy) / delta
    b = (sum_y - k * sum_x) / n
    return k, b
end

function vandermonde_matrix(x::AbstractVector{<:Real}, m::Integer)
    n = length(x)
    A = zeros(Float64, n, m + 1)
    for j in 0:m
        A[:, j + 1] .= x .^ j
    end
    return A
end

function polynomial_least_squares(x::AbstractVector{<:Real}, y::AbstractVector{<:Real}, m::Integer)
    n = length(x)
    @assert n == length(y) "x and y must have the same length"
    @assert 0 <= m <= n - 1 "Degree m must satisfy 0 <= m <= n - 1"

    A = vandermonde_matrix(x, m)
    AtA = A' * A
    Aty = A' * Float64.(y)
    coeffs = AtA \ Aty
    return coeffs, A
end

function eval_polynomial(coeffs::AbstractVector{<:Real}, x_val::Real)
    val = 0.0
    for a in reverse(coeffs)
        val = val * x_val + a
    end
    return val
end

function web_spec()
    return Dict(
        "order" => 1,
        "title" => "Ապրոքսիմացիա",
        "actions" => [
            Dict(
                "id" => "fit",
                "title" => "Տվյալներ և պարամետրեր",
                "presets" => [
                    Dict(
                        "label" => "Օրինակ 1 (4 կետ)",
                        "values" => Dict("x" => "2, 4, 5, 6", "y" => "7, 3, 6, 8", "m" => 2)
                    ),
                    Dict(
                        "label" => "Օրինակ 2 (8 կետ)",
                        "values" => Dict("x" => "0, 1, 2, 3, 4, 5, 6, 7", "y" => "2.1, 2.5, 1.4, 4.9, 8.2, 18.8, 13.1, 26.5", "m" => 2)
                    )
                ],
                "fields" => [
                    Dict("name" => "x", "label" => "x կոորդինատներ (ստորակետով)", "type" => "vector", "default" => "2, 4, 5, 6"),
                    Dict("name" => "y", "label" => "y կոորդինատներ (ստորակետով)", "type" => "vector", "default" => "7, 3, 6, 8"),
                    Dict("name" => "m", "label" => "Բազմանդամի աստիճան m", "type" => "range", "min" => 1, "max" => 10, "default" => 2)
                ]
            )
        ]
    )
end

function web_run(action, params)
    x = Float64.(params["x"])
    y = Float64.(params["y"])
    m = Int(params["m"])

    k, b = linear_least_squares(x, y)
    coeffs, _ = polynomial_least_squares(x, y, m)

    xmin, xmax = extrema(x)
    pad = max(0.5, 0.1 * (xmax - xmin))
    x_grid = collect(range(xmin - pad, xmax + pad, length=120))
    y_lin_grid = k .* x_grid .+ b
    y_poly_grid = [eval_polynomial(coeffs, xi) for xi in x_grid]
    y_poly_pts = [eval_polynomial(coeffs, xi) for xi in x]

    sse_linear = sum((y .- (k .* x .+ b)) .^ 2)
    sse_poly = sum((y .- y_poly_pts) .^ 2)

    res_x = Union{Float64, Nothing}[]
    res_y = Union{Float64, Nothing}[]
    for i in eachindex(x)
        push!(res_x, x[i], x[i], nothing)
        push!(res_y, y[i], y_poly_pts[i], nothing)
    end

    terms = String[]
    for (i, c) in enumerate(coeffs)
        deg = i - 1
        if deg == 0
            push!(terms, @sprintf("%.4f", c))
        else
            sign_str = c >= 0 ? "+" : ""
            var_str = deg == 1 ? "x" : "x^$deg"
            push!(terms, @sprintf("%s%.4f%s", sign_str, c, var_str))
        end
    end
    poly_str = join(terms, " ")

    text = @sprintf(
        "Գծային՝ y = %.5fx + %.5f\nՍխալ S_linear = %.5f\n\nԲազմանդամ (m=%d)՝\nP(x) = %s\nՍխալ S_poly = %.5f",
        k, b, sse_linear, m, poly_str, sse_poly
    )

    return Dict(
        "text" => text,
        "plots" => [
            Dict(
                "type" => "plotly",
                "title" => "Գծային և բազմանդամային մոտարկում",
                "height" => "470px",
                "click_add" => Dict("x" => "x", "y" => "y"),
                "traces" => [
                    Dict("x" => res_x, "y" => res_y, "mode" => "lines", "name" => "Շեղումներ (residuals)", "line" => Dict("color" => "#94a3b8", "dash" => "dot", "width" => 1.5)),
                    Dict("x" => x_grid, "y" => y_lin_grid, "mode" => "lines", "name" => "Գծային (m=1)", "line" => Dict("color" => "#f59e0b", "dash" => "dash", "width" => 2.5)),
                    Dict("x" => x_grid, "y" => y_poly_grid, "mode" => "lines", "name" => "Բազմանդամ (m=$m)", "line" => Dict("color" => "#2563eb", "width" => 3)),
                    Dict("x" => x, "y" => y, "mode" => "markers", "name" => "Տրված կետեր", "marker" => Dict("color" => "#dc2626", "size" => 10))
                ],
                "layout" => Dict(
                    "margin" => Dict("t" => 20, "r" => 20, "l" => 45, "b" => 40),
                    "xaxis" => Dict("title" => "x"),
                    "yaxis" => Dict("title" => "y")
                )
            )
        ]
    )
end

if abspath(PROGRAM_FILE) == @__FILE__
    x = [2.0, 4.0, 5.0, 6.0]
    y = [7.0, 3.0, 6.0, 8.0]

    println("=== Chapter 1: Linear Approximation ===")
    k, b = linear_least_squares(x, y)
    @printf("y = %.6f * x + %.6f\n", k, b)
    @printf("Exact from thesis: k = 8/35 = %.6f, b = 176/35 = %.6f\n", 8 / 35, 176 / 35)
    sse_linear = sum((y .- (k .* x .+ b)) .^ 2)
    @printf("Residual sum of squares S(k, b) = %.6f\n\n", sse_linear)

    println("=== Chapter 2: Polynomial Approximation (m = 2) ===")
    m = 2
    coeffs, A = polynomial_least_squares(x, y, m)
    @printf("P(x) = %.6f + (%.6f)*x + (%.6f)*x^2\n", coeffs[1], coeffs[2], coeffs[3])
    @printf("Exact from thesis: a0 = 983/55 = %.6f, a1 = -149/20 = %.6f, a2 = 43/44 = %.6f\n",
            983 / 55, -149 / 20, 43 / 44)
    y_pred = [eval_polynomial(coeffs, xi) for xi in x]
    sse_poly = sum((y .- y_pred) .^ 2)
    @printf("Residual sum of squares S(a0, a1, a2) = %.6f\n", sse_poly)
end