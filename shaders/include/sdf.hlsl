// SDF primitives and combinators

// Sphere
float sdSphere(float3 p, float r) {
    return length(p) - r;
}

// Ellipsoid
float sdEllipsoid(float3 p, float3 r) {
    float k0 = length(p / r);
    float k1 = length(p / (r * r));
    return k0 * (k0 - 1.0) / max(k1, 0.001);
}

// Box
float sdBox(float3 p, float3 b) {
    float3 q = abs(p) - b;
    return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0);
}

// Torus
float sdTorus(float3 p, float2 t) {
    float2 q = float2(length(p.xz) - t.x, p.y);
    return length(q) - t.y;
}

// Capsule
float sdCapsule(float3 p, float3 a, float3 b, float r) {
    float3 pa = p - a, ba = b - a;
    float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    return length(pa - ba * h) - r;
}

// Cylinder
float sdCylinder(float3 p, float h, float r) {
    float2 d = float2(length(p.xz) - r, abs(p.y) - h);
    return min(max(d.x, d.y), 0.0) + length(max(d, 0.0));
}

// Cone
float sdCone(float3 p, float h, float r1, float r2) {
    float2 q = float2(r1, -h) + (r2 - r1) * clamp(p.y / h, 0.0, 1.0);
    return max(length(float2(p.x, p.z)) - q.x, q.y);
}

// Plane
float sdPlane(float3 p, float3 n, float h) {
    return dot(p, n) + h;
}

// Octahedron
float sdOctahedron(float3 p, float s) {
    p = abs(p);
    return (p.x + p.y + p.z - s) * 0.57735027;
}

// Smooth minimum — blend shapes
float smin(float a, float b, float k) {
    float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return lerp(b, a, h) - k * h * (1.0 - h);
}

// Hard minimum with chamfer
float chamferMin(float a, float b, float r) {
    return min(min(a, b), (a - r + b) * 0.5);
}

// Maximum
float smax(float a, float b, float k) {
    float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return lerp(b, a, h) + k * h * (1.0 - h);
}

// Subtraction
float opSub(float a, float b) {
    return max(a, -b);
}

// Intersection
float opInter(float a, float b) {
    return max(a, b);
}

// Elongation
float opElongate(float3 p, float3 h, float sdf) {
    float3 q = abs(p) - h;
    return min(sdf, length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0));
}

// Domain repetition
float3 opRep(float3 p, float3 c) {
    return p - c * floor(p / c + 0.5);
}

// Twist
float3 opTwist(float3 p, float k) {
    float c = cos(k * p.y);
    float s = sin(k * p.y);
    return float3(c * p.x - s * p.z, p.y, s * p.x + c * p.z);
}

// Mandelbulb SDF — audio-driven power parameter
float mandelbulbSDF(float3 p, float power, float distort) {
    float3 z = p;
    float dr = 1.0;
    float r = 0.0;
    [unroll] for (int i = 0; i < 4; i++) {
        r = length(z);
        if (r > 2.0) break;
        float theta = acos(z.z / max(r, 0.001)) * power;
        float phi = atan2(z.y, z.x) * power;
        float st = sin(theta);
        z = pow(r, power) * float3(st * cos(phi), st * sin(phi), cos(theta)) + p;
        dr = pow(r, power - 1.0) * power * dr + 1.0;
    }
    return 0.5 * log(max(r, 0.001)) * r / max(dr, 0.001);
}
