import Foundation

/// The whole effect in two kinds of pass.
///
/// `blurPass` builds the blur stack: one weighted sum of linear samples per
/// pixel, with the taps worked out on the CPU (see `BlurStack`).
///
/// `depthFragment` draws the frame. Each screen pixel maps back into the
/// picture through the inverse perspective, then blends the two stack levels
/// that bracket the blur wanted there. Where there is almost no blur it reads
/// the sharp picture itself. The stack already holds the picture on black, so
/// the two blur together and the picture edge needs no special handling.
enum DepthShaders {
    /// Taps a blur pass can take. Matches `BlurStack.maximumTaps`.
    static let maximumTaps = 8

    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    // All float4, so the layout cannot drift from the Swift side.
    struct Uniforms {
        float4 column0;          // framebuffer-to-stack matrix, column 0 in xyz
        float4 column1;
        float4 column2;
        float4 picture;          // stack to picture coordinates: scale, offset
        float4 blur;             // sigma at the hinge, sigma range, top level, sharp filter
        float4 extent;           // stack size in picture pixels, size of its first mip
        float4 light;            // max dim, dim floor, dim strength, dim reach
    };

    struct PassUniforms {
        float4 frame;            // output to input coordinates: scale, offset
        float4 count;            // tap count, unused, 1 / output size
        float4 taps[\(maximumTaps)];   // input offset, weight, unused
    };

    vertex float4 depthVertex(uint vertexID [[vertex_id]]) {
        const float2 corners[3] = { float2(-1.0, -3.0), float2(-1.0, 1.0), float2(3.0, 1.0) };
        return float4(corners[vertexID], 0.0, 1.0);
    }

    // Each tap count gets its own pipeline, so the loop unrolls and the
    // samples go out back to back instead of one per iteration.
    constant int tapCount [[function_constant(0)]];

    fragment float4 blurPass(float4 position [[position]],
                             constant PassUniforms &uniforms [[buffer(0)]],
                             texture2d<float> input [[texture(0)]]) {
        // Outside the input is the black margin.
        constexpr sampler linearSampler(filter::linear, address::clamp_to_border,
                                        border_color::opaque_black);
        float2 coordinate = position.xy * uniforms.count.zw * uniforms.frame.xy + uniforms.frame.zw;
        float3 sum = float3(0.0);
        for (int index = 0; index < tapCount; ++index) {
            float4 tap = uniforms.taps[index];
            sum += input.sample(linearSampler, coordinate + tap.xy, level(0.0)).rgb * tap.z;
        }
        return float4(sum, 1.0);
    }

    struct CubicAxis {
        float3 coordinates;
        half3 weights;
    };

    CubicAxis catmullRomAxis(float coordinate, float size) {
        float point = coordinate * size - 0.5;
        float base = floor(point);
        half fraction = half(point - base);

        // Catmull-Rom interpolates: at a texel centre it returns that texel
        // alone, so a flat picture comes out exactly as captured. The middle
        // weights are positive, so one linear sample evaluates both exactly.
        half w0 = fraction * (-0.5h + fraction * (1.0h - 0.5h * fraction));
        half w1 = 1.0h + fraction * fraction * (-2.5h + 1.5h * fraction);
        half w2 = fraction * (0.5h + fraction * (2.0h - 1.5h * fraction));
        half w3 = fraction * fraction * (-0.5h + 0.5h * fraction);
        half middleWeight = w1 + w2;

        CubicAxis axis;
        axis.coordinates = (
            base + float3(-0.5, 0.5 + float(w2 / middleWeight), 2.5)
        ) / size;
        axis.weights = half3(w0, middleWeight, w3);
        return axis;
    }

    half4 sharpSample(texture2d<half> picture, sampler linearSampler, float2 coordinate, float2 size) {
        // Near the hinge the leaning picture is magnified, and a single
        // linear sample would soften it. This is the 4x4 Catmull-Rom filter
        // in five linear samples: the four corner samples carry products of
        // the small outer weights, under half a percent, so they are left
        // out and the rest renormalised.
        CubicAxis x = catmullRomAxis(coordinate.x, size.x);
        CubicAxis y = catmullRomAxis(coordinate.y, size.y);
        half4 colour
            = picture.sample(linearSampler, float2(x.coordinates.y, y.coordinates.x), level(0.0)) * (x.weights.y * y.weights.x)
            + picture.sample(linearSampler, float2(x.coordinates.x, y.coordinates.y), level(0.0)) * (x.weights.x * y.weights.y)
            + picture.sample(linearSampler, float2(x.coordinates.y, y.coordinates.y), level(0.0)) * (x.weights.y * y.weights.y)
            + picture.sample(linearSampler, float2(x.coordinates.z, y.coordinates.y), level(0.0)) * (x.weights.z * y.weights.y)
            + picture.sample(linearSampler, float2(x.coordinates.y, y.coordinates.z), level(0.0)) * (x.weights.y * y.weights.z);
        half total = x.weights.y * (y.weights.x + y.weights.y + y.weights.z)
            + y.weights.y * (x.weights.x + x.weights.z);
        return colour / total;
    }

    half4 smallBlur(texture2d<half> picture,
                    sampler linearSampler,
                    float2 coordinate,
                    float2 size,
                    float sigma,
                    half4 centre) {
        // A Gaussian of under a pixel or so, straight from the sharp picture:
        // five texels each way, grouped into three linear samples. Blending
        // the sharp picture with a wider stack level gives the same variance,
        // but reads as a sharp copy with a halo rather than a blur. At sigma
        // 0 this is the centre sample alone.
        float falloff = exp(-0.5 / max(sigma * sigma, 1e-4));
        float far = falloff * falloff;
        far *= far;
        float side = falloff + far;
        half middle = half(1.0 / (1.0 + 2.0 * side));
        half outer = half(side) * middle;
        float2 offset = (1.0 + far / max(side, 1e-6)) / size;
        half4 cross = picture.sample(linearSampler, coordinate + float2(offset.x, 0.0), level(0.0))
            + picture.sample(linearSampler, coordinate - float2(offset.x, 0.0), level(0.0))
            + picture.sample(linearSampler, coordinate + float2(0.0, offset.y), level(0.0))
            + picture.sample(linearSampler, coordinate - float2(0.0, offset.y), level(0.0));
        half4 corners = picture.sample(linearSampler, coordinate + offset, level(0.0))
            + picture.sample(linearSampler, coordinate - offset, level(0.0))
            + picture.sample(linearSampler, coordinate + float2(offset.x, -offset.y), level(0.0))
            + picture.sample(linearSampler, coordinate + float2(-offset.x, offset.y), level(0.0));
        return centre * (middle * middle) + cross * (middle * outer) + corners * (outer * outer);
    }

    half4 stackSample(texture2d_array<half> stack,
                      sampler linearSampler,
                      float2 coordinate,
                      float2 baseSize,
                      uint index) {
        // Stack level n lives in slice n % 2 at mip n / 2, and every mip is
        // exactly half the one before.
        uint slice = index & 1u;
        uint lod = index >> 1u;
        float2 size = ldexp(baseSize, -int(lod));

        // A cubic B-spline over the level's texels, in four linear samples.
        // One linear sample shows the coarse texel grid as soft diamonds; the
        // B-spline is smooth to the second derivative, so there is no grid to
        // see. Its own spread is part of each level's blur.
        float2 point = coordinate * size - 0.5;
        float2 base = floor(point);
        half2 f = half2(point - base);
        half2 f2 = f * f;
        half2 f3 = f2 * f;
        half2 w0 = (1.0h - 3.0h * f + 3.0h * f2 - f3) / 6.0h;
        half2 w1 = (4.0h - 6.0h * f2 + 3.0h * f3) / 6.0h;
        half2 w2 = (1.0h + 3.0h * f + 3.0h * f2 - 3.0h * f3) / 6.0h;
        half2 w3 = f3 / 6.0h;
        half2 g0 = w0 + w1;
        half2 g1 = w2 + w3;
        float2 h0 = (base - 0.5 + float2(w1 / g0)) / size;
        float2 h1 = (base + 1.5 + float2(w3 / g1)) / size;
        // Naming this `level` would shadow Metal's level() selector.
        float mip = float(lod);
        return (stack.sample(linearSampler, h0, slice, level(mip)) * g0.x
                + stack.sample(linearSampler, float2(h1.x, h0.y), slice, level(mip)) * g1.x) * g0.y
            + (stack.sample(linearSampler, float2(h0.x, h1.y), slice, level(mip)) * g0.x
               + stack.sample(linearSampler, h1, slice, level(mip)) * g1.x) * g1.y;
    }

    fragment half4 depthFragment(float4 position [[position]],
                                  constant Uniforms &uniforms [[buffer(0)]],
                                  texture2d<half> picture [[texture(0)]],
                                  texture2d_array<half> stack [[texture(1)]]) {
        constexpr sampler pictureSampler(filter::linear, address::clamp_to_border,
                                         border_color::opaque_black);
        constexpr sampler stackSampler(filter::linear, mip_filter::nearest, address::clamp_to_edge);
        const half4 black = half4(0.0h, 0.0h, 0.0h, 1.0h);

        float hingeSigma = uniforms.blur.x;
        float sigmaRange = uniforms.blur.y;
        uint topLevel = uint(uniforms.blur.z);
        bool sharpFilter = uniforms.blur.w > 0.0;
        float2 baseSize = uniforms.extent.zw;
        float maxDim = uniforms.light.x;
        float dimFloor = uniforms.light.y;
        float dimStrength = uniforms.light.z;
        float dimReach = uniforms.light.w;

        float3x3 pixelToStack = float3x3(uniforms.column0.xyz,
                                         uniforms.column1.xyz,
                                         uniforms.column2.xyz);
        float3 mapped = pixelToStack * float3(position.xy, 1.0);
        if (abs(mapped.z) < 1e-6) { return black; }
        float2 stackCoord = mapped.xy / mapped.z;
        if (any(stackCoord < 0.0) || any(stackCoord > 1.0)) { return black; }
        float2 pictureCoord = stackCoord * uniforms.picture.xy + uniforms.picture.zw;

        float height = saturate(1.0 - pictureCoord.y);
        // smoothstep rather than a clamped ratio, so the height where the
        // dimming reaches full strength leaves no visible edge.
        float spread = smoothstep(0.0, max(dimReach, 0.02), height);
        float fade = dimStrength * (dimFloor + (1.0 - dimFloor) * spread);
        // The sample is linear light. Raising the factor to 2.2 keeps the
        // dimming setting a fraction of the encoded brightness.
        float light = pow(max(1.0 - maxDim * fade, 0.0), 2.2);
        // Fully dimmed rows need no samples at all.
        if (light <= 0.0) { return black; }

        // Keep the hinge edge nearly sharp and concentrate the blur toward
        // the far edge: height^2.25, as two square roots instead of a pow.
        // The response curve also keeps modest lid travel from jumping into
        // a strong blur.
        float blurSigma = hingeSigma + sigmaRange * height * height * sqrt(sqrt(height));

        // Where the lean squeezes several picture pixels into one screen
        // pixel, widen the blur to cover them, or fine detail shimmers as the
        // lid moves. The derivatives of the projection are exact here, so
        // there is no quad or branch to worry about.
        float2 alongX = (uniforms.column0.xy - stackCoord * uniforms.column0.z) / mapped.z * uniforms.extent.xy;
        float2 alongY = (uniforms.column1.xy - stackCoord * uniforms.column1.z) / mapped.z * uniforms.extent.xy;
        float footprint = max(dot(alongX, alongX), dot(alongY, alongY));
        float variance = blurSigma * blurSigma + 0.25 * max(footprint - 1.0, 0.0);

        // Level n has a Gaussian blur of sigma 2^(1 + n / 2) picture pixels,
        // half an octave apart, so its variance is 2^(n + 2). Blending two
        // levels by variance gives the blur wanted in between, and at half an
        // octave the blend is close to a single Gaussian rather than a sharp
        // copy with a halo. Under a sigma of 2 the blur comes from the
        // picture itself.
        half4 colour;
        if (variance < 4.0) {
            float2 pictureSize = float2(picture.get_width(), picture.get_height());
            if (variance < 1.0) {
                half4 centre = sharpFilter
                    ? sharpSample(picture, pictureSampler, pictureCoord, pictureSize)
                    : picture.sample(pictureSampler, pictureCoord, level(0.0));
                colour = variance > 0.004
                    ? smallBlur(picture, pictureSampler, pictureCoord, pictureSize, sqrt(variance), centre)
                    : centre;
            } else {
                half4 centre = picture.sample(pictureSampler, pictureCoord, level(0.0));
                colour = mix(smallBlur(picture, pictureSampler, pictureCoord, pictureSize, 1.0, centre),
                             stackSample(stack, stackSampler, stackCoord, baseSize, 0u),
                             half((variance - 1.0) / 3.0));
            }
        } else {
            // The exponent picks the level below and the mantissa is the
            // blend: variance = 2^(n + 2) * (1 + weight).
            int exponent;
            float mantissa = frexp(variance, exponent);
            uint lower = uint(exponent - 3);
            half weight = half(2.0 * mantissa - 1.0);
            if (lower >= topLevel) {
                colour = stackSample(stack, stackSampler, stackCoord, baseSize, topLevel);
            } else {
                colour = stackSample(stack, stackSampler, stackCoord, baseSize, lower);
                if (weight > 0.002h) {
                    colour = mix(colour, stackSample(stack, stackSampler, stackCoord, baseSize, lower + 1u), weight);
                }
            }
        }

        float3 linearColour = float3(saturate(colour.rgb)) * light;
        // A wide blur of a dimmed picture is a slow gradient, and eight bits
        // show it as contour bands. Noise of under half a step breaks them up
        // and leaves exact values exact. The target encodes to sRGB, so the
        // step is scaled by the slope of the curve, roughly 2.2 sqrt(x).
        float noise = fract(52.9829189 * fract(dot(position.xy, float2(0.06711056, 0.00583715))));
        float3 step = max(2.2 * sqrt(linearColour), 1.0 / 12.92) * (0.6 / 255.0);
        return half4(half3(max(linearColour + (noise - 0.5) * step, 0.0)), 1.0h);
    }
    """
}
