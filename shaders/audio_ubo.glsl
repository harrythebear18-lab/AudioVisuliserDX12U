#version 460 core

// Shared UBO block — all brain outputs exposed to every shader.
// Binding point 0, std140 layout.
//
// Layout (12 vec4s = 192 bytes):
//   u_bands          = (sub, bass, low_mid, mid)
//   u_bands2         = (high_mid, presence, brilliance, air)
//   u_dynamics       = (beat_intensity, transient, envelope, overall)
//   u_rhythm         = (bpm, tempo_confidence, kick_level, kick_confidence)
//   u_stereo         = (stereo_balance, stereo_width, effect_intensity, movement_intensity)
//   u_color_hue      = (base_hue, section_hue_center, section_hue_range, beat_detected)
//   u_intensities    = (dimmer, laser, blinder, moving_light)
//   u_intensities2   = (static_light, random_flash, group_phase, section_confidence)
//   u_triggers       = (flash, strobe, smoke, pyro)
//   u_fixtures       = (moving_on, lasers_on, static_on, blinders_on)
//   u_group          = (behavior_mode, desired_effect_mode, beat_count, phrase_beat)
//   u_section_info   = (section, strobe_on, should_change_effect, 0)

layout(std140, binding = 0) uniform AudioBlock {
    vec4 u_bands;
    vec4 u_bands2;
    vec4 u_dynamics;
    vec4 u_rhythm;
    vec4 u_stereo;
    vec4 u_color_hue;
    vec4 u_intensities;
    vec4 u_intensities2;
    vec4 u_triggers;
    vec4 u_fixtures;
    vec4 u_group;
    vec4 u_section_info;
};

#define BAND_SUB        u_bands.x
#define BAND_BASS       u_bands.y
#define BAND_LOW_MID    u_bands.z
#define BAND_MID        u_bands.w
#define BAND_HIGH_MID   u_bands2.x
#define BAND_PRESENCE   u_bands2.y
#define BAND_BRILLIANCE u_bands2.z
#define BAND_AIR        u_bands2.w

#define BEAT_INTENSITY  u_dynamics.x
#define TRANSIENT       u_dynamics.y
#define ENVELOPE        u_dynamics.z
#define OVERALL         u_dynamics.w

#define BPM             u_rhythm.x
#define TEMPO_CONF      u_rhythm.y
#define KICK_LEVEL      u_rhythm.z
#define KICK_CONF       u_rhythm.w

#define STEREO_BALANCE  u_stereo.x
#define STEREO_WIDTH    u_stereo.y
#define EFFECT_INT      u_stereo.z
#define MOVEMENT_INT    u_stereo.w

#define BASE_HUE        u_color_hue.x
#define SECTION_HUE_CTR u_color_hue.y
#define SECTION_HUE_RNG u_color_hue.z
#define BEAT_DETECTED   u_color_hue.w

#define DIMMER_INT      u_intensities.x
#define LASER_INT       u_intensities.y
#define BLINDER_INT     u_intensities.z
#define MOVING_LIGHT_INT u_intensities.w

#define STATIC_LIGHT_INT u_intensities2.x
#define RANDOM_FLASH    u_intensities2.y
#define GROUP_PHASE     u_intensities2.z
#define SECTION_CONF    u_intensities2.w

#define TRIGGER_FLASH   u_triggers.x
#define TRIGGER_STROBE  u_triggers.y
#define TRIGGER_SMOKE   u_triggers.z
#define TRIGGER_PYRO    u_triggers.w

#define MOVING_ON       u_fixtures.x
#define LASERS_ON       u_fixtures.y
#define STATIC_ON       u_fixtures.z
#define BLINDERS_ON     u_fixtures.w

#define BEHAVIOR_MODE   u_group.x
#define EFFECT_MODE     u_group.y
#define BEAT_COUNT      u_group.z
#define PHRASE_BEAT     u_group.w

#define SECTION         u_section_info.x
#define STROBE_ON       u_section_info.y
#define SHOULD_CHANGE   u_section_info.z

// Spectrum textures — bound at fixed units
// unit 0 = mono spectrum, unit 1 = L spectrum, unit 2 = R spectrum
