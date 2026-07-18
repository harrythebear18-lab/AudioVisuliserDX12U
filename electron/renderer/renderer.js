// RTX Audio Visualizer — Electron WebGL2 Renderer
// Uses ANGLE (D3D11 on Windows) for hardware-accelerated shader rendering.
// Connects to C# AudioServer via WebSocket for WASAPI audio data.

const canvas = document.getElementById('glcanvas');
const hud = document.getElementById('hud');
const modeName = document.getElementById('mode-name');
const errorOverlay = document.getElementById('error-overlay');

const gl = canvas.getContext('webgl2', {
  antialias: true,
  alpha: false,
  premultipliedAlpha: false,
  powerPreference: 'high-performance',
  desynchronized: true,
});

if (!gl) {
  errorOverlay.style.display = 'block';
  errorOverlay.textContent = 'WebGL2 not supported. Need Chrome/Electron with GPU acceleration.';
  throw new Error('No WebGL2');
}

console.log('WebGL2 context created');
console.log('Renderer:', gl.getParameter(gl.RENDERER));
console.log('Vendor:', gl.getParameter(gl.VENDOR));
console.log('Max texture size:', gl.getParameter(gl.MAX_TEXTURE_SIZE));

// === Shader sources ===

const VS_SOURCE = `#version 300 es
in vec2 a_pos;
in vec2 a_uv;
out vec2 v_uv;
void main() {
  v_uv = a_uv;
  gl_Position = vec4(a_pos, 0.0, 1.0);
}`;

// Plasma Globe — volumetric raymarched plasma sphere
const PLASMA_GLOBE_FS = `#version 300 es
precision highp float;
in vec2 v_uv;
out vec4 fragColor;

uniform float u_time;
uniform vec2 u_resolution;
uniform float u_band_sub, u_band_bass, u_band_low_mid, u_band_mid;
uniform float u_band_high_mid, u_band_presence, u_band_brilliance, u_band_air;
uniform float u_beat_intensity, u_beat_detected, u_kick_level;
uniform float u_stereo_balance, u_stereo_width, u_movement_int;
uniform float u_base_hue, u_section_hue_ctr, u_section_hue_rng;
uniform float u_dimmer_int, u_section, u_phrase_beat;
uniform float u_strobe_on, u_trigger_flash, u_trigger_pyro;

#define PI 3.14159265359

float sectionEnergy(float s) {
  if (s < 0.5) return 0.0;
  if (s < 1.5) return 0.15;
  if (s < 2.5) return 0.4;
  if (s < 3.5) return 0.5;
  if (s < 4.5) return 0.6;
  if (s < 5.5) return 0.7;
  if (s < 6.5) return 1.0;
  if (s < 7.5) return 0.5;
  if (s < 8.5) return 0.45;
  if (s < 9.5) return 0.3;
  return 0.1;
}

vec3 hsv2rgb(float h, float s, float v) {
  vec4 K = vec4(1.0, 2.0/3.0, 1.0/3.0, 3.0);
  vec3 p = abs(fract(vec3(h) + K.xyz) * 6.0 - K.www);
  return v * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), s);
}

float hash21(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }

float noise(vec2 p) {
  vec2 i = floor(p), f = fract(p);
  f = f * f * (3.0 - 2.0 * f);
  return mix(mix(hash21(i), hash21(i + vec2(1,0)), f.x),
             mix(hash21(i + vec2(0,1)), hash21(i + vec2(1,1)), f.x), f.y);
}

float fbm(vec2 p) {
  float v = 0.0, a = 0.5;
  for (int i = 0; i < 6; i++) { v += a * noise(p); p *= 2.13; a *= 0.5; }
  return v;
}

mat2 rot2(float a) { return mat2(cos(a), -sin(a), sin(a), cos(a)); }

float flow(vec3 p, float t, float secEnergy) {
  float turb = u_band_mid * 0.5 + u_band_high_mid * 0.3 + secEnergy * 0.4;
  vec2 q = vec2(fbm(p.xy * 2.0 + t * 0.1), fbm(p.yz * 2.0 + t * 0.12));
  vec2 r = vec2(fbm(p.xy * 3.0 + q * (2.0 + turb) + t * 0.05),
                fbm(p.zx * 3.0 + q * (2.0 + turb) + t * 0.08));
  float f = fbm(p.xy + r * (1.5 + turb * 0.5));
  f += fbm(p.zx + r * 1.2) * 0.5;
  f += sin(length(p) * 15.0 - t * 8.0) * u_beat_intensity * 0.3;
  f += exp(-length(p) * 3.0) * u_kick_level * 0.5;
  return f;
}

vec3 vmarch(vec3 ro, vec3 rd, float t, float secEnergy, float brightness) {
  vec3 sum = vec3(0.0);
  vec3 p = ro;
  for (int i = 0; i < 24; i++) {
    p += rd * 0.05;
    float lp = length(p);
    float f = flow(p, t, secEnergy);
    vec3 col = sin(vec3(1.05, 2.5, 1.52) * 3.94 + f * 5.0) * 0.85 + 0.4;
    col = mix(col, hsv2rgb(u_base_hue + u_section_hue_ctr, 0.7, 1.0), 0.3);
    col *= smoothstep(0.04, 0.2, abs(lp - 1.0));
    col *= smoothstep(0.1, 0.34, lp);
    col *= (0.5 + u_beat_intensity * 0.5 + u_band_bass * 0.3);
    float depthAtten = 1.0 / (log(length(p - ro) - 1.5) + 0.75);
    sum += abs(col) * 5.0 * depthAtten * brightness;
  }
  return sum;
}

void main() {
  vec2 p = (v_uv - 0.5) * 2.0;
  p.x *= u_resolution.x / u_resolution.y;

  float t = u_time * 0.2 + u_movement_int * 2.0;
  float secEnergy = sectionEnergy(u_section);
  float brightness = 0.3 + u_dimmer_int * 0.7;

  vec3 ro = vec3(0.0, 0.0, 3.0);
  vec3 rd = normalize(vec3(p * 0.7, -1.5));

  float camRot = t * 0.3 + u_stereo_balance * 0.5 + u_phrase_beat * PI / 32.0;
  mat2 mx = rot2(camRot);
  ro.xz = mx * ro.xz;
  rd.xz = mx * rd.xz;

  vec3 col = vec3(0.012, 0.0, 0.025) * brightness;

  for (int j = 0; j < 8; j++) {
    float fj = float(j) + 1.0;
    vec3 rro = ro, rrd = rd;
    mat2 mm = rot2((t * 0.1 + fj * 5.1) * fj * 0.25);
    rro.xy = mm * rro.xy; rrd.xy = mm * rrd.xy;
    rro.xz = mm * rro.xz; rrd.xz = mm * rrd.xz;

    vec3 oc = rro;
    float b = dot(oc, rrd);
    float c = dot(oc, oc) - 1.0;
    float h = b * b - c;
    if (h > 0.0) {
      float tz = -b - sqrt(h);
      vec3 pos = rro + rrd * tz;
      col = max(col, vmarch(pos, rrd, t, secEnergy, brightness));
    }
  }

  // Sphere reflection glow
  vec3 oc2 = ro;
  float b2 = dot(oc2, rd);
  float c2 = dot(oc2, oc2) - 1.0;
  float h2 = b2 * b2 - c2;
  if (h2 > 0.0) {
    vec3 pos = ro + rd * (-b2 - sqrt(h2));
    vec3 rf = reflect(rd, pos);
    float nz = -log(abs(flow(rf * 1.2, t, secEnergy) - 0.01));
    col += 0.1 * nz * nz * vec3(0.12, 0.12, 0.5) * brightness;
  }

  // Background stars
  float star = hash21(floor(p * 30.0));
  if (star > 0.996)
    col += vec3(0.7, 0.8, 1.0) * (star - 0.996) * 250.0 * brightness * 0.3;

  // Fixture effects
  if (u_strobe_on > 0.5) {
    float strobe = step(0.5, fract(t * (8.0 + u_band_high_mid * 10.0)));
    col += vec3(1.0) * strobe * 0.15 * brightness;
  }
  col += vec3(1.0) * u_trigger_flash * 0.4;
  if (u_trigger_pyro > 0.5)
    col += vec3(1.0, 0.5, 0.1) * exp(-length(p) * 3.0) * 0.5;

  // Tone map
  col = (col * (2.51 * col + 0.03)) / (col * (2.43 * col + 0.59) + 0.14);
  col = pow(col, vec3(0.85));
  col *= 1.0 - dot(v_uv - 0.5, v_uv - 0.5) * 0.4;

  fragColor = vec4(col, 1.0);
}`;

// Test shader — simple gradient
const TEST_FS = `#version 300 es
precision highp float;
in vec2 v_uv;
out vec4 fragColor;
uniform float u_time;
uniform vec2 u_resolution;
void main() {
  vec3 col = vec3(v_uv.x, v_uv.y, 0.5 + 0.5 * sin(u_time));
  fragColor = vec4(col, 1.0);
}`;

// === Shader compilation helpers ===

function compileShader(type, source) {
  const shader = gl.createShader(type);
  gl.shaderSource(shader, source);
  gl.compileShader(shader);
  if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
    const err = gl.getShaderInfoLog(shader);
    console.error('Shader compile error:', err);
    gl.deleteShader(shader);
    throw new Error('Shader compile: ' + err);
  }
  return shader;
}

function createProgram(vsSource, fsSource) {
  const vs = compileShader(gl.VERTEX_SHADER, vsSource);
  const fs = compileShader(gl.FRAGMENT_SHADER, fsSource);
  const prog = gl.createProgram();
  gl.attachShader(prog, vs);
  gl.attachShader(prog, fs);
  gl.linkProgram(prog);
  if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) {
    const err = gl.getProgramInfoLog(prog);
    console.error('Program link error:', err);
    throw new Error('Program link: ' + err);
  }
  gl.deleteShader(vs);
  gl.deleteShader(fs);
  return prog;
}

// === Fullscreen quad ===

const quadVerts = new Float32Array([
  -1, -1,  0, 0,
   1, -1,  1, 0,
  -1,  1,  0, 1,
   1,  1,  1, 1,
]);

const vbo = gl.createBuffer();
gl.bindBuffer(gl.ARRAY_BUFFER, vbo);
gl.bufferData(gl.ARRAY_BUFFER, quadVerts, gl.STATIC_DRAW);

// === Mode system ===

const MODES = [
  { name: 'Plasma Globe', fs: PLASMA_GLOBE_FS },
  { name: 'Test Gradient', fs: TEST_FS },
];

let currentMode = 0;
let programs = [];

for (let i = 0; i < MODES.length; i++) {
  try {
    const prog = createProgram(VS_SOURCE, MODES[i].fs);
    programs.push(prog);
    console.log(`Loaded mode ${i}: ${MODES[i].name}`);
  } catch (e) {
    console.error(`Failed to load mode ${i} (${MODES[i].name}):`, e.message);
    errorOverlay.style.display = 'block';
    errorOverlay.textContent += `Mode ${i} (${MODES[i].name}): ${e.message}\n`;
    programs.push(null);
  }
}

modeName.textContent = MODES[currentMode].name;

// === Uniform locations cache ===

function getUniforms(prog) {
  return {
    u_time: gl.getUniformLocation(prog, 'u_time'),
    u_resolution: gl.getUniformLocation(prog, 'u_resolution'),
    u_band_sub: gl.getUniformLocation(prog, 'u_band_sub'),
    u_band_bass: gl.getUniformLocation(prog, 'u_band_bass'),
    u_band_low_mid: gl.getUniformLocation(prog, 'u_band_low_mid'),
    u_band_mid: gl.getUniformLocation(prog, 'u_band_mid'),
    u_band_high_mid: gl.getUniformLocation(prog, 'u_band_high_mid'),
    u_band_presence: gl.getUniformLocation(prog, 'u_band_presence'),
    u_band_brilliance: gl.getUniformLocation(prog, 'u_band_brilliance'),
    u_band_air: gl.getUniformLocation(prog, 'u_band_air'),
    u_beat_intensity: gl.getUniformLocation(prog, 'u_beat_intensity'),
    u_beat_detected: gl.getUniformLocation(prog, 'u_beat_detected'),
    u_kick_level: gl.getUniformLocation(prog, 'u_kick_level'),
    u_stereo_balance: gl.getUniformLocation(prog, 'u_stereo_balance'),
    u_stereo_width: gl.getUniformLocation(prog, 'u_stereo_width'),
    u_movement_int: gl.getUniformLocation(prog, 'u_movement_int'),
    u_base_hue: gl.getUniformLocation(prog, 'u_base_hue'),
    u_section_hue_ctr: gl.getUniformLocation(prog, 'u_section_hue_ctr'),
    u_section_hue_rng: gl.getUniformLocation(prog, 'u_section_hue_rng'),
    u_dimmer_int: gl.getUniformLocation(prog, 'u_dimmer_int'),
    u_section: gl.getUniformLocation(prog, 'u_section'),
    u_phrase_beat: gl.getUniformLocation(prog, 'u_phrase_beat'),
    u_strobe_on: gl.getUniformLocation(prog, 'u_strobe_on'),
    u_trigger_flash: gl.getUniformLocation(prog, 'u_trigger_flash'),
    u_trigger_pyro: gl.getUniformLocation(prog, 'u_trigger_pyro'),
  };
}

let uniformLocs = programs.map(p => p ? getUniforms(p) : null);

// === Audio data ===

let audioData = {
  bands: [0,0,0,0,0,0,0,0],
  beatIntensity: 0, beatDetected: 0, kickLevel: 0,
  stereoBalance: 0, stereoWidth: 0, movementInt: 0,
  baseHue: 0, sectionHueCenter: 0, sectionHueRange: 0,
  dimmerIntensity: 0, section: 0, phraseBeat: 0,
  strobeOn: 0, triggerFlash: 0, triggerPyro: 0,
  bpm: 0, overall: 0,
};

// === WebSocket connection to C# AudioServer ===

let ws = null;
let wsConnected = false;

function connectWS() {
  hud.textContent = 'Connecting to audio server...';
  ws = new WebSocket('ws://localhost:8765/audio');

  ws.onopen = () => {
    wsConnected = true;
    hud.textContent = 'Connected — WASAPI audio active';
    console.log('WebSocket connected to AudioServer');
  };

  ws.onmessage = (event) => {
    try {
      const d = JSON.parse(event.data);
      audioData.bands = d.bands || [0,0,0,0,0,0,0,0];
      audioData.beatIntensity = d.beatIntensity || 0;
      audioData.beatDetected = d.beatDetected || 0;
      audioData.kickLevel = d.kickLevel || 0;
      audioData.stereoBalance = d.stereoBalance || 0;
      audioData.stereoWidth = d.stereoWidth || 0;
      audioData.movementInt = d.movementIntensity || 0;
      audioData.baseHue = d.baseHue || 0;
      audioData.sectionHueCenter = d.sectionHueCenter || 0;
      audioData.sectionHueRange = d.sectionHueRange || 0;
      audioData.dimmerIntensity = d.dimmerIntensity || 0;
      audioData.section = d.section || 0;
      audioData.phraseBeat = d.phraseBeat || 0;
      audioData.strobeOn = d.strobeOn || 0;
      audioData.triggerFlash = d.triggerFlash || 0;
      audioData.triggerPyro = d.triggerPyro || 0;
      audioData.bpm = d.bpm || 0;
      audioData.overall = d.overall || 0;
    } catch (e) {
      console.error('Parse error:', e);
    }
  };

  ws.onerror = (e) => {
    console.error('WebSocket error:', e);
    hud.textContent = 'Audio server error — check console';
  };

  ws.onclose = () => {
    wsConnected = false;
    hud.textContent = 'Disconnected — retrying in 2s...';
    setTimeout(connectWS, 2000);
  };
}

connectWS();

// === Keyboard controls ===

document.addEventListener('keydown', (e) => {
  if (e.key === 'm' || e.key === 'M') {
    currentMode = (currentMode + 1) % MODES.length;
    modeName.textContent = MODES[currentMode].name;
    console.log('Mode:', MODES[currentMode].name);
  } else if (e.key === 'n' || e.key === 'N') {
    currentMode = (currentMode - 1 + MODES.length) % MODES.length;
    modeName.textContent = MODES[currentMode].name;
    console.log('Mode:', MODES[currentMode].name);
  }
});

// === Resize ===

function resize() {
  const dpr = Math.min(window.devicePixelRatio, 2);
  canvas.width = window.innerWidth * dpr;
  canvas.height = window.innerHeight * dpr;
  gl.viewport(0, 0, canvas.width, canvas.height);
}
window.addEventListener('resize', resize);
resize();

// === Render loop ===

const startTime = performance.now();

function render() {
  const time = (performance.now() - startTime) / 1000.0;

  gl.clearColor(0, 0, 0, 1);
  gl.clear(gl.COLOR_BUFFER_BIT);

  const prog = programs[currentMode];
  if (!prog) {
    requestAnimationFrame(render);
    return;
  }

  gl.useProgram(prog);

  // Bind quad
  gl.bindBuffer(gl.ARRAY_BUFFER, vbo);
  const posLoc = gl.getAttribLocation(prog, 'a_pos');
  const uvLoc = gl.getAttribLocation(prog, 'a_uv');
  gl.enableVertexAttribArray(posLoc);
  gl.vertexAttribPointer(posLoc, 2, gl.FLOAT, false, 16, 0);
  if (uvLoc >= 0) {
    gl.enableVertexAttribArray(uvLoc);
    gl.vertexAttribPointer(uvLoc, 2, gl.FLOAT, false, 16, 8);
  }

  // Set uniforms
  const u = uniformLocs[currentMode];
  if (u.u_time) gl.uniform1f(u.u_time, time);
  if (u.u_resolution) gl.uniform2f(u.u_resolution, canvas.width, canvas.height);
  if (u.u_band_sub) gl.uniform1f(u.u_band_sub, audioData.bands[0] || 0);
  if (u.u_band_bass) gl.uniform1f(u.u_band_bass, audioData.bands[1] || 0);
  if (u.u_band_low_mid) gl.uniform1f(u.u_band_low_mid, audioData.bands[2] || 0);
  if (u.u_band_mid) gl.uniform1f(u.u_band_mid, audioData.bands[3] || 0);
  if (u.u_band_high_mid) gl.uniform1f(u.u_band_high_mid, audioData.bands[4] || 0);
  if (u.u_band_presence) gl.uniform1f(u.u_band_presence, audioData.bands[5] || 0);
  if (u.u_band_brilliance) gl.uniform1f(u.u_band_brilliance, audioData.bands[6] || 0);
  if (u.u_band_air) gl.uniform1f(u.u_band_air, audioData.bands[7] || 0);
  if (u.u_beat_intensity) gl.uniform1f(u.u_beat_intensity, audioData.beatIntensity);
  if (u.u_beat_detected) gl.uniform1f(u.u_beat_detected, audioData.beatDetected);
  if (u.u_kick_level) gl.uniform1f(u.u_kick_level, audioData.kickLevel);
  if (u.u_stereo_balance) gl.uniform1f(u.u_stereo_balance, audioData.stereoBalance);
  if (u.u_stereo_width) gl.uniform1f(u.u_stereo_width, audioData.stereoWidth);
  if (u.u_movement_int) gl.uniform1f(u.u_movement_int, audioData.movementInt);
  if (u.u_base_hue) gl.uniform1f(u.u_base_hue, audioData.baseHue);
  if (u.u_section_hue_ctr) gl.uniform1f(u.u_section_hue_ctr, audioData.sectionHueCenter);
  if (u.u_section_hue_rng) gl.uniform1f(u.u_section_hue_rng, audioData.sectionHueRange);
  if (u.u_dimmer_int) gl.uniform1f(u.u_dimmer_int, audioData.dimmerIntensity);
  if (u.u_section) gl.uniform1f(u.u_section, audioData.section);
  if (u.u_phrase_beat) gl.uniform1f(u.u_phrase_beat, audioData.phraseBeat);
  if (u.u_strobe_on) gl.uniform1f(u.u_strobe_on, audioData.strobeOn);
  if (u.u_trigger_flash) gl.uniform1f(u.u_trigger_flash, audioData.triggerFlash);
  if (u.u_trigger_pyro) gl.uniform1f(u.u_trigger_pyro, audioData.triggerPyro);

  gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);

  // Update HUD
  if (wsConnected && (performance.now() % 500 < 16)) {
    hud.textContent = `BPM:${audioData.bpm.toFixed(0)} | Beat:${audioData.beatIntensity.toFixed(2)} | Section:${audioData.section} | Phrase:${audioData.phraseBeat}`;
  }

  requestAnimationFrame(render);
}

render();
