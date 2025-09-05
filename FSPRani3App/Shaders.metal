#include <metal_stdlib>
using namespace metal;

// Ball Tracker Shaders - Camera feed + detection overlay in single pass

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// Fullscreen triangle for camera pass
vertex VertexOut trackerVertex(uint vid [[vertex_id]]) {
    VertexOut out;
    
    // Fullscreen triangle
    float2 positions[3] = {
        float2(-1.0, -1.0),
        float2(-1.0,  3.0),
        float2( 3.0, -1.0)
    };
    
    // Flip Y - even though buffer is rotated, texture origin is still top-left
    float2 texCoords[3] = {
        float2(0.0, 1.0),  // flip Y
        float2(0.0, -1.0), // flip Y
        float2(2.0, 1.0)   // flip Y
    };
    
    out.position = float4(positions[vid], 0.0, 1.0);
    out.texCoord = texCoords[vid];
    return out;
}

// Get label color based on ID
float3 getLabelColor(int id) {
    switch(id) {
        case 1: return float3(0.0, 1.0, 0.3);  // Sports ball - Green
        case 2: return float3(0.2, 0.6, 1.0);  // Person - Blue
        case 3: return float3(1.0, 0.8, 0.0);  // Chair - Yellow
        case 4: return float3(1.0, 0.3, 0.0);  // Skateboard - Orange
        case 5: return float3(0.8, 0.0, 0.8);  // Knife - Purple
        case 6: return float3(0.0, 0.8, 0.8);  // TV - Cyan
        case 7: return float3(0.5, 1.0, 0.0);  // Frisbee - Lime
        default: return float3(0.7, 0.7, 0.7); // Unknown - Gray
    }
}

// Camera + detection overlay fragment shader
fragment float4 trackerFragment(VertexOut in [[stage_in]],
                               texture2d<float, access::sample> yTexture [[texture(0)]],
                               texture2d<float, access::sample> uvTexture [[texture(1)]],
                               constant float4& detectionBox [[buffer(0)]], // x, y, width, height in normalized coords
                               constant float& detectionStrength [[buffer(1)]],
                               constant float2& aspectRatio [[buffer(2)]],
                               constant float4& cropRegion [[buffer(3)]], // Debug: show Vision crop area
                               constant float& showCrop [[buffer(4)]],
                               constant int& labelID [[buffer(5)]]) {
    
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    
    // Show FULL camera view with proper letterboxing
    float2 uv = in.texCoord;
    float2 originalUV = uv; // Keep original UV
    
    // Scale to show full view
    uv = (uv - 0.5) / aspectRatio + 0.5;
    
    // Letterbox: Show black bars outside valid texture range
    float3 rgb = float3(0.0, 0.0, 0.0); // Default to black
    
    if (uv.x >= 0.0 && uv.x <= 1.0 && uv.y >= 0.0 && uv.y <= 1.0) {
        // Sample YUV and convert to RGB only within valid range
        float y = yTexture.sample(textureSampler, uv).r;
        float2 yuv_uv = uvTexture.sample(textureSampler, uv).rg - 0.5;
        
        // BT.709 conversion
        rgb.r = y + 1.5748 * yuv_uv.y;
        rgb.g = y - 0.1873 * yuv_uv.x - 0.4681 * yuv_uv.y;
        rgb.b = y + 1.8556 * yuv_uv.x;
        rgb = saturate(rgb);
    }
    
    // Debug: Show crop region with subtle outline (use original UV before aspect correction)
    if (showCrop > 0.5) {
        float2 cropMin = float2(cropRegion.x, cropRegion.y);
        float2 cropMax = float2(cropRegion.x + cropRegion.z, cropRegion.y + cropRegion.w);
        
        // Check if we're near the edge of the crop region using ORIGINAL UV
        float edgeThickness = 0.002;
        bool nearLeftEdge = abs(originalUV.x - cropMin.x) < edgeThickness && 
                           originalUV.y >= cropMin.y && originalUV.y <= cropMax.y;
        bool nearRightEdge = abs(originalUV.x - cropMax.x) < edgeThickness && 
                            originalUV.y >= cropMin.y && originalUV.y <= cropMax.y;
        bool nearTopEdge = abs(originalUV.y - cropMin.y) < edgeThickness && 
                          originalUV.x >= cropMin.x && originalUV.x <= cropMax.x;
        bool nearBottomEdge = abs(originalUV.y - cropMax.y) < edgeThickness && 
                             originalUV.x >= cropMin.x && originalUV.x <= cropMax.x;
        
        if (nearLeftEdge || nearRightEdge || nearTopEdge || nearBottomEdge) {
            // Draw subtle white outline for crop region
            rgb = mix(rgb, float3(1.0, 1.0, 1.0), 0.3);
        }
        
        // Add corner markers to verify squareness
        float2 corners[4] = {
            float2(cropMin.x, cropMin.y),  // Top-left
            float2(cropMax.x, cropMin.y),  // Top-right
            float2(cropMin.x, cropMax.y),  // Bottom-left
            float2(cropMax.x, cropMax.y)   // Bottom-right
        };
        
        for (int i = 0; i < 4; i++) {
            if (distance(originalUV, corners[i]) < 0.005) {
                rgb = float3(1.0, 0.0, 0.0); // Red corners for visibility
            }
        }
    }
    
    // Check if we have a detection and we're in the valid image area
    if (detectionStrength > 0.01 && uv.x >= 0.0 && uv.x <= 1.0 && uv.y >= 0.0 && uv.y <= 1.0) {
        // Transform detection box to match the scaled/letterboxed view
        // Detection coords are in camera space, need to transform to display space
        float2 boxMin = float2(detectionBox.x, detectionBox.y);
        float2 boxMax = float2(detectionBox.x + detectionBox.z, detectionBox.y + detectionBox.w);
        
        // Apply same aspect ratio transformation as the image
        boxMin = (boxMin - 0.5) * aspectRatio + 0.5;
        boxMax = (boxMax - 0.5) * aspectRatio + 0.5;
        
        float2 boxCenter = (boxMin + boxMax) * 0.5;
        float2 boxSize = boxMax - boxMin;
        
        // Use originalUV (screen space) for distance calculations
        float2 distFromCenter = abs(originalUV - boxCenter);
        float2 halfSize = boxSize * 0.5;
        float2 distToEdge = distFromCenter - halfSize;
        float distanceToBox = length(max(distToEdge, 0.0));
        
        // Smoother edge detection with gradient
        float edgeThickness = 0.008;
        float bloomRadius = 0.04; // Increased bloom radius
        float innerGlow = 0.02;
        
        // Calculate edge proximity with smooth falloff
        float edgeFactor = 0.0;
        if (abs(distToEdge.x) < edgeThickness && distFromCenter.y < halfSize.y) {
            edgeFactor = 1.0 - smoothstep(0.0, edgeThickness, abs(distToEdge.x));
        }
        if (abs(distToEdge.y) < edgeThickness && distFromCenter.x < halfSize.x) {
            edgeFactor = max(edgeFactor, 1.0 - smoothstep(0.0, edgeThickness, abs(distToEdge.y)));
        }
        
        // Get color based on detected object type
        float3 boxColor = getLabelColor(labelID);
        float pulseAmount = sin(detectionStrength * 3.14159) * 0.3 + 0.7; // Gentle pulse
        boxColor *= pulseAmount * (0.5 + detectionStrength * 0.5); // Modulate by confidence
        
        // Apply edge with smooth blending
        if (edgeFactor > 0.0) {
            rgb = mix(rgb, boxColor, edgeFactor * detectionStrength * 0.9);
        }
        
        // Enhanced bloom effect outside the box
        if (distanceToBox > 0.0 && distanceToBox < bloomRadius) {
            float bloomFactor = 1.0 - smoothstep(0.0, bloomRadius, distanceToBox);
            bloomFactor = pow(bloomFactor, 1.5); // Softer falloff
            float3 glowColor = boxColor * 0.5;
            rgb += glowColor * bloomFactor * detectionStrength * 0.4;
        }
        
        // Inner glow for high confidence
        if (distToEdge.x < 0 && distToEdge.y < 0) {
            float innerDist = length(distToEdge);
            if (innerDist > -innerGlow) {
                float innerFactor = 1.0 - smoothstep(-innerGlow, 0.0, innerDist);
                rgb += boxColor * innerFactor * detectionStrength * 0.15;
            }
        }
        
        // Add label indicator badge in top-left corner of box
        float2 badgeCenter = boxMin + float2(0.03, 0.03);
        float badgeRadius = 0.015;
        float distToBadge = distance(originalUV, badgeCenter);
        
        if (distToBadge < badgeRadius) {
            // Draw solid colored circle badge
            float badgeFactor = 1.0 - smoothstep(badgeRadius * 0.8, badgeRadius, distToBadge);
            rgb = mix(rgb, boxColor, badgeFactor * 0.9);
            
            // Add white highlight in center for visibility
            if (distToBadge < badgeRadius * 0.3) {
                rgb = mix(rgb, float3(1.0, 1.0, 1.0), 0.3);
            }
        }
    }
    
    return float4(rgb, 1.0);
}

// Advanced fragment shader with smooth gradients and bloom

fragment float4 trackerFragmentAdvanced(VertexOut in [[stage_in]],
                                         texture2d<float, access::sample> yTexture [[texture(0)]],
                                         texture2d<float, access::sample> uvTexture [[texture(1)]],
                                         constant float4& detectionBox [[buffer(0)]],
                                         constant float& detectionStrength [[buffer(1)]],
                                         constant float2& aspectRatio [[buffer(2)]]) {
    
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    
    float2 uv = in.texCoord;
    
    // Apply same correction as main shader - show full view
    uv = (uv - 0.5) / aspectRatio + 0.5;
    
    // Letterbox: Return black outside valid range
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
        return float4(0.0, 0.0, 0.0, 1.0);
    }
    
    // YUV to RGB
    float y = yTexture.sample(textureSampler, uv).r;
    float2 yuv_uv = uvTexture.sample(textureSampler, uv).rg - 0.5;
    
    float3 rgb;
    rgb.r = y + 1.5748 * yuv_uv.y;
    rgb.g = y - 0.1873 * yuv_uv.x - 0.4681 * yuv_uv.y;
    rgb.b = y + 1.8556 * yuv_uv.x;
    rgb = saturate(rgb);
    
    if (detectionStrength > 0.01) {
        float2 boxCenter = float2(detectionBox.x + detectionBox.z * 0.5,
                                  1.0 - (detectionBox.y + detectionBox.w * 0.5));
        float2 boxSize = float2(detectionBox.z, detectionBox.w);
        
        // Distance from pixel to box center
        float2 fromCenter = abs(uv - boxCenter);
        float2 halfSize = boxSize * 0.5;
        
        // Compute distance to box edge (negative = inside, positive = outside)
        float2 distToEdge = fromCenter - halfSize;
        float dist = length(max(distToEdge, 0.0)) + min(max(distToEdge.x, distToEdge.y), 0.0);
        
        // Create gradient effect
        float edgeWidth = 0.01;
        float glowRadius = 0.02;
        
        if (dist < edgeWidth && dist > -edgeWidth) {
            // On the edge - strong color
            float edgeFactor = 1.0 - smoothstep(0.0, edgeWidth, abs(dist));
            
            float3 edgeColor;
            if (detectionStrength > 0.9) {
                edgeColor = float3(0.0, 1.0, 0.3); // Neon green
            } else {
                // Fade from yellow to red
                float t = detectionStrength;
                edgeColor = mix(float3(1.0, 0.2, 0.0), float3(1.0, 1.0, 0.0), t);
            }
            
            rgb = mix(rgb, edgeColor, edgeFactor * detectionStrength);
        } else if (dist < glowRadius) {
            // Glow effect outside box
            float glowFactor = 1.0 - smoothstep(edgeWidth, glowRadius, dist);
            float3 glowColor = float3(0.0, detectionStrength, 0.0);
            rgb = mix(rgb, rgb + glowColor * 0.3, glowFactor * detectionStrength);
        } else if (dist < 0) {
            // Inside box - subtle highlight
            float insideFactor = smoothstep(-halfSize.x * 0.5, 0.0, dist);
            rgb *= 1.0 + insideFactor * detectionStrength * 0.2;
        }
    }
    
    return float4(rgb, 1.0);
}