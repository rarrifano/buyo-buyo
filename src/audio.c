/*
 * audio: a tiny software synthesizer + sample/stream playback.
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 *  - voices: square (PolyBLEP), triangle, saw (PolyBLEP), sine, noise;
 *    exponential pitch slides, attack/release/decay envelopes, vibrato, pan.
 *  - music: a step sequencer running inside the audio callback, so note
 *    timing is sample accurate. Songs are described from Lua as note strings.
 *
 * Lua API:
 *   audio.play{ wave=, freq=, to=, dur=, vol=, attack=, release=, decay=,
 *               duty=, pan=, delay=, vib=, vibrate= }
 *   audio.music{ bpm=, spb=4, loop=true, channels = {
 *                  { wave=, vol=, duty=, pan=, attack=, release=, decay=,
 *                    legato=, transpose=, vib=, vibrate=,
 *                    notes = "C4 - E4 . G4 | ..." },          -- melodic
 *                  { drums=true, vol=, notes = "K . H . S . H ." } } }
 *   audio.stop_music()   audio.stop()   audio.volume(master, sfx, music)
 *
 *   audio.load(path) -> Sample | nil, err         (WAV or OGG, any rate/channels)
 *   audio.play_sample(sample [, vol [, pan [, pitch]]])
 *   sample:duration() -> seconds
 *   audio.music_file(path [, { loop = true, loop_start = 0, volume = 1 }])
 *                                                  (streams OGG, or plays WAV)
 *
 * Note tokens: C4 D#5 Eb3 (note), "-" (hold previous), "." (rest), "|" (ignored).
 * Drum tokens: K kick, S snare, H closed hat, O open hat, C crash, T tom.
 */
#include "engine.h"

#define STB_VORBIS_HEADER_ONLY
#define STB_VORBIS_NO_STDIO
#include "stb_vorbis.c"

#include <ctype.h>
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define MAX_VOICES 48
#define MAX_SVOICES 24
#define SAMPLE_MT "buyo.Sample"
#define OGG_CHUNK 2048
#define MAX_CHANNELS 8
#define TAU 6.283185307179586

enum { W_SQUARE, W_TRIANGLE, W_SAW, W_SINE, W_NOISE };
enum { BUS_SFX, BUS_MUSIC };

typedef struct {
    int wave, bus;
    double freq, freq_end, dur, vol, pan, attack, release, decay, duty, delay;
    double vib_depth, vib_rate;
} VoiceParams;

typedef struct {
    bool active;
    int wave, bus;
    double phase, freq, fmul, duty;
    long pos, len, delay, attack, release;
    double decay_mul, decay_env;
    double vib_depth, vib_step, vib_phase;
    float gl, gr;
    uint32_t rng;
    float noise;
    unsigned age;
} Voice;

typedef struct {
    int note; /* midi note / drum id, or -1 */
    int len;  /* length in steps */
} Step;

typedef struct {
    int wave;
    bool drums;
    double vol, pan, duty, attack, release, decay, legato, vib_depth, vib_rate;
    int transpose;
    int nsteps;
    Step *steps;
} Channel;

typedef struct {
    double samples_per_step, acc;
    long step, total_steps;
    bool loop;
    int nch;
    Channel ch[MAX_CHANNELS];
} Song;

static SDL_AudioDeviceID dev;
static int sample_rate = 48000;
static Voice voices[MAX_VOICES];
static unsigned age_counter;
static Song *song;
static float master_vol = 0.9f, sfx_vol = 0.8f, music_vol = 0.6f;

/* decoded audio: interleaved stereo float at the device rate */
typedef struct {
    float *data;
    int frames;
} Pcm;

typedef struct {
    Pcm *pcm;
} SampleUD;

typedef struct {
    bool active;
    const Pcm *pcm;
    double pos, step;
    float gl, gr;
    unsigned age;
} SampleVoice;

static SampleVoice svoices[MAX_SVOICES];

/* file music: OGG decoded on the fly (from memory), or a decoded WAV */
typedef struct {
    unsigned char *file;
    stb_vorbis *vorb;
    int channels, rate, chunk_ch, chunk_len, chunk_pos;
    float chunk[OGG_CHUNK * 2];
    float a[2], b[2];
    double t, step;
    unsigned loop_start_src;
    Pcm *pcm;
    double pos;
    int loop_start_pcm;
    bool loop, finished;
    float vol;
} Stream;

static Stream *stream;

/* ------------------------------------------------------------------ */
/* voices                                                              */
/* ------------------------------------------------------------------ */

static void voice_start(const VoiceParams *vp) {
    Voice *v = NULL;
    for (int i = 0; i < MAX_VOICES; i++) {
        if (!voices[i].active) {
            v = &voices[i];
            break;
        }
    }
    if (!v) { /* steal the oldest voice */
        unsigned best = 0;
        v = &voices[0];
        for (int i = 0; i < MAX_VOICES; i++) {
            unsigned age = age_counter - voices[i].age;
            if (age >= best) {
                best = age;
                v = &voices[i];
            }
        }
    }
    memset(v, 0, sizeof *v);
    v->active = true;
    v->wave = vp->wave;
    v->bus = vp->bus;
    v->freq = vp->freq > 1.0 ? vp->freq : 1.0;
    double fe = vp->freq_end > 1.0 ? vp->freq_end : v->freq;
    v->len = (long)(vp->dur * sample_rate);
    if (v->len < 1)
        v->len = 1;
    v->fmul = pow(fe / v->freq, 1.0 / (double)v->len);
    v->duty = vp->duty > 0.01 && vp->duty < 0.99 ? vp->duty : 0.5;
    v->delay = (long)(vp->delay * sample_rate);
    v->attack = (long)(vp->attack * sample_rate);
    v->release = (long)(vp->release * sample_rate);
    v->decay_mul = vp->decay > 0.0 ? exp(-vp->decay / sample_rate) : 1.0;
    v->decay_env = 1.0;
    v->vib_depth = vp->vib_depth;
    v->vib_step = vp->vib_rate / sample_rate;
    double pan = vp->pan < -1 ? -1 : vp->pan > 1 ? 1 : vp->pan;
    v->gl = (float)(vp->vol * (pan > 0 ? 1.0 - pan : 1.0));
    v->gr = (float)(vp->vol * (pan < 0 ? 1.0 + pan : 1.0));
    v->rng = 0x9E3779B9u ^ (age_counter * 2654435761u) ^ 0x1234567u;
    v->age = age_counter++;
}

static inline double poly_blep(double t, double dt) {
    if (t < dt) {
        t /= dt;
        return t + t - t * t - 1.0;
    }
    if (t > 1.0 - dt) {
        t = (t - 1.0) / dt;
        return t * t + t + t + 1.0;
    }
    return 0.0;
}

static inline float voice_sample(Voice *v) {
    double f = v->freq;
    if (v->vib_depth > 0.0) {
        f *= pow(2.0, v->vib_depth * sin(TAU * v->vib_phase) / 12.0);
        v->vib_phase += v->vib_step;
    }
    double dt = f / sample_rate;
    double bdt = dt > 0.5 ? 0.5 : dt;
    double t = v->phase, s;
    switch (v->wave) {
        case W_SQUARE: {
            s = t < v->duty ? 1.0 : -1.0;
            s += poly_blep(t, bdt);
            double t2 = t + (1.0 - v->duty);
            if (t2 >= 1.0)
                t2 -= 1.0;
            s -= poly_blep(t2, bdt);
            s *= 0.7; /* squares are loud */
            break;
        }
        case W_TRIANGLE:
            s = t < 0.5 ? 4.0 * t - 1.0 : 3.0 - 4.0 * t;
            break;
        case W_SAW:
            s = (2.0 * t - 1.0 - poly_blep(t, bdt)) * 0.7;
            break;
        case W_SINE:
            s = sin(TAU * t);
            break;
        default:
            s = v->noise;
            break;
    }
    v->phase += dt;
    while (v->phase >= 1.0) {
        v->phase -= 1.0;
        if (v->wave == W_NOISE) {
            uint32_t x = v->rng;
            x ^= x << 13;
            x ^= x >> 17;
            x ^= x << 5;
            v->rng = x;
            v->noise = (float)((x >> 8) & 0xFFFF) / 32767.5f - 1.0f;
        }
    }
    v->freq *= v->fmul;

    double env = v->decay_env;
    v->decay_env *= v->decay_mul;
    if (v->attack > 0 && v->pos < v->attack)
        env *= (double)v->pos / (double)v->attack;
    long rem = v->len - v->pos;
    if (v->release > 0 && rem < v->release)
        env *= (double)rem / (double)v->release;

    if (++v->pos >= v->len)
        v->active = false;
    return (float)(s * env);
}

/* ------------------------------------------------------------------ */
/* music sequencer                                                     */
/* ------------------------------------------------------------------ */

static double midi_freq(int n) {
    return 440.0 * pow(2.0, (n - 69) / 12.0);
}

static void trigger_drum(const Channel *ch, int id) {
    VoiceParams a = {0};
    a.bus = BUS_MUSIC;
    a.pan = ch->pan;
    switch (id) {
        case 0: /* kick */
            a.wave = W_SINE;
            a.freq = 150;
            a.freq_end = 42;
            a.dur = 0.22;
            a.vol = 0.95 * ch->vol;
            a.decay = 14;
            voice_start(&a);
            a.wave = W_NOISE;
            a.freq = 3000;
            a.freq_end = 800;
            a.dur = 0.02;
            a.vol = 0.25 * ch->vol;
            a.decay = 0;
            voice_start(&a);
            break;
        case 1: /* snare */
            a.wave = W_NOISE;
            a.freq = 9000;
            a.freq_end = 5000;
            a.dur = 0.16;
            a.vol = 0.45 * ch->vol;
            a.decay = 22;
            voice_start(&a);
            a.wave = W_TRIANGLE;
            a.freq = 210;
            a.freq_end = 140;
            a.dur = 0.09;
            a.vol = 0.5 * ch->vol;
            a.decay = 20;
            voice_start(&a);
            break;
        case 2: /* closed hat */
            a.wave = W_NOISE;
            a.freq = 22000;
            a.dur = 0.04;
            a.vol = 0.18 * ch->vol;
            a.decay = 60;
            voice_start(&a);
            break;
        case 3: /* open hat */
            a.wave = W_NOISE;
            a.freq = 20000;
            a.dur = 0.22;
            a.vol = 0.15 * ch->vol;
            a.decay = 12;
            voice_start(&a);
            break;
        case 4: /* crash */
            a.wave = W_NOISE;
            a.freq = 16000;
            a.dur = 1.0;
            a.vol = 0.2 * ch->vol;
            a.decay = 4;
            voice_start(&a);
            break;
        case 5: /* tom */
            a.wave = W_SINE;
            a.freq = 240;
            a.freq_end = 120;
            a.dur = 0.2;
            a.vol = 0.6 * ch->vol;
            a.decay = 12;
            voice_start(&a);
            break;
    }
}

static void music_tick(Song *s) {
    s->acc += 1.0;
    if (s->acc < s->samples_per_step)
        return;
    s->acc -= s->samples_per_step;
    for (int c = 0; c < s->nch; c++) {
        const Channel *ch = &s->ch[c];
        if (ch->nsteps == 0)
            continue;
        if (!s->loop && s->step >= ch->nsteps)
            continue;
        const Step *st = &ch->steps[s->step % ch->nsteps];
        if (st->note < 0)
            continue;
        if (ch->drums) {
            trigger_drum(ch, st->note);
        } else {
            VoiceParams a = {0};
            a.bus = BUS_MUSIC;
            a.wave = ch->wave;
            a.freq = a.freq_end = midi_freq(st->note + ch->transpose);
            a.dur = st->len * s->samples_per_step / sample_rate * ch->legato;
            a.vol = ch->vol;
            a.pan = ch->pan;
            a.attack = ch->attack;
            a.release = fmin(ch->release, a.dur * 0.5);
            a.decay = ch->decay;
            a.duty = ch->duty;
            a.vib_depth = ch->vib_depth;
            a.vib_rate = ch->vib_rate;
            voice_start(&a);
        }
    }
    s->step++;
}

static void free_song(Song *s) {
    if (!s)
        return;
    for (int i = 0; i < s->nch; i++)
        free(s->ch[i].steps);
    free(s);
}

/* ------------------------------------------------------------------ */
/* samples + streams                                                   */
/* ------------------------------------------------------------------ */

static void free_pcm(Pcm *p) {
    if (!p)
        return;
    free(p->data);
    free(p);
}

static void free_stream(Stream *st) {
    if (!st)
        return;
    if (st->vorb)
        stb_vorbis_close(st->vorb);
    free(st->file);
    free_pcm(st->pcm);
    free(st);
}

/* convert any SDL-supported PCM to stereo float at the device rate */
static Pcm *pcm_convert(const void *src, int bytes, SDL_AudioFormat fmt, int channels, int rate) {
    SDL_AudioStream *as =
        SDL_NewAudioStream(fmt, (Uint8)channels, rate, AUDIO_F32SYS, 2, sample_rate);
    if (!as)
        return NULL;
    if (SDL_AudioStreamPut(as, src, bytes) != 0 || SDL_AudioStreamFlush(as) != 0) {
        SDL_FreeAudioStream(as);
        return NULL;
    }
    int avail = SDL_AudioStreamAvailable(as);
    Pcm *p = (Pcm *)calloc(1, sizeof *p);
    if (p)
        p->data = (float *)malloc(avail > 0 ? (size_t)avail : 8);
    if (!p || !p->data) {
        free(p);
        SDL_FreeAudioStream(as);
        return NULL;
    }
    int got = SDL_AudioStreamGet(as, p->data, avail);
    SDL_FreeAudioStream(as);
    p->frames = got > 0 ? got / (int)(sizeof(float) * 2) : 0;
    return p;
}

static bool is_ogg(const unsigned char *d, size_t len) {
    return len >= 4 && d[0] == 'O' && d[1] == 'g' && d[2] == 'g' && d[3] == 'S';
}

/* decode a whole WAV or OGG file already in memory */
static Pcm *decode_pcm(const unsigned char *file, size_t len, const char *path, char *err,
                       size_t errlen) {
    Pcm *p = NULL;
    if (is_ogg(file, len)) {
        int ch = 0, rate = 0;
        short *out = NULL;
        int frames = stb_vorbis_decode_memory(file, (int)len, &ch, &rate, &out);
        if (frames > 0 && out && ch > 0)
            p = pcm_convert(out, frames * ch * (int)sizeof(short), AUDIO_S16SYS, ch, rate);
        free(out);
        if (!p)
            snprintf(err, errlen, "%s: cannot decode OGG", path);
    } else {
        SDL_AudioSpec spec;
        Uint8 *buf = NULL;
        Uint32 blen = 0;
        if (SDL_LoadWAV_RW(SDL_RWFromConstMem(file, (int)len), 1, &spec, &buf, &blen)) {
            p = pcm_convert(buf, (int)blen, spec.format, spec.channels, spec.freq);
            SDL_FreeWAV(buf);
            if (!p)
                snprintf(err, errlen, "%s: cannot convert audio", path);
        } else {
            snprintf(err, errlen, "%s: not a WAV or OGG file (%s)", path, SDL_GetError());
        }
    }
    return p;
}

static bool ogg_pull(Stream *s, float *out) {
    if (s->chunk_pos >= s->chunk_len) {
        int ch = s->channels >= 2 ? 2 : 1;
        int n = stb_vorbis_get_samples_float_interleaved(s->vorb, ch, s->chunk, OGG_CHUNK * ch);
        if (n <= 0) {
            if (!s->loop)
                return false;
            if (!stb_vorbis_seek(s->vorb, s->loop_start_src))
                stb_vorbis_seek_start(s->vorb);
            n = stb_vorbis_get_samples_float_interleaved(s->vorb, ch, s->chunk, OGG_CHUNK * ch);
            if (n <= 0)
                return false;
        }
        s->chunk_ch = ch;
        s->chunk_len = n;
        s->chunk_pos = 0;
    }
    if (s->chunk_ch == 2) {
        out[0] = s->chunk[s->chunk_pos * 2];
        out[1] = s->chunk[s->chunk_pos * 2 + 1];
    } else {
        out[0] = out[1] = s->chunk[s->chunk_pos];
    }
    s->chunk_pos++;
    return true;
}

static bool stream_frame(Stream *s, float *l, float *r) {
    if (s->finished)
        return false;
    if (s->pcm) {
        if ((int)s->pos >= s->pcm->frames) {
            if (!s->loop || s->pcm->frames == 0) {
                s->finished = true;
                return false;
            }
            s->pos = s->loop_start_pcm < s->pcm->frames ? s->loop_start_pcm : 0;
        }
        int i = (int)s->pos;
        *l = s->pcm->data[i * 2];
        *r = s->pcm->data[i * 2 + 1];
        s->pos += 1.0;
        return true;
    }
    while (s->t >= 1.0) {
        s->a[0] = s->b[0];
        s->a[1] = s->b[1];
        if (!ogg_pull(s, s->b)) {
            s->finished = true;
            return false;
        }
        s->t -= 1.0;
    }
    *l = s->a[0] + (s->b[0] - s->a[0]) * (float)s->t;
    *r = s->a[1] + (s->b[1] - s->a[1]) * (float)s->t;
    s->t += s->step;
    return true;
}

/* ------------------------------------------------------------------ */
/* device                                                              */
/* ------------------------------------------------------------------ */

static void audio_cb(void *ud, Uint8 *bytes, int len) {
    (void)ud;
    float *out = (float *)bytes;
    int frames = len / (int)(sizeof(float) * 2);
    for (int i = 0; i < frames; i++) {
        if (song)
            music_tick(song);
        float l = 0.f, r = 0.f;
        for (int k = 0; k < MAX_VOICES; k++) {
            Voice *v = &voices[k];
            if (!v->active)
                continue;
            if (v->delay > 0) {
                v->delay--;
                continue;
            }
            float s = voice_sample(v) * (v->bus == BUS_MUSIC ? music_vol : sfx_vol);
            l += s * v->gl;
            r += s * v->gr;
        }
        for (int k = 0; k < MAX_SVOICES; k++) {
            SampleVoice *v = &svoices[k];
            if (!v->active)
                continue;
            int p = (int)v->pos;
            if (p >= v->pcm->frames) {
                v->active = false;
                continue;
            }
            l += v->pcm->data[p * 2] * v->gl * sfx_vol;
            r += v->pcm->data[p * 2 + 1] * v->gr * sfx_vol;
            v->pos += v->step;
        }
        if (stream) {
            float sl, sr;
            if (stream_frame(stream, &sl, &sr)) {
                l += sl * stream->vol * music_vol;
                r += sr * stream->vol * music_vol;
            }
        }
        out[2 * i] = tanhf(l * master_vol);
        out[2 * i + 1] = tanhf(r * master_vol);
    }
}

bool audio_init(bool enabled) {
    if (!enabled)
        return false;
    if (!SDL_WasInit(SDL_INIT_AUDIO) && SDL_InitSubSystem(SDL_INIT_AUDIO) != 0) {
        SDL_Log("audio disabled: %s", SDL_GetError());
        return false;
    }
    SDL_AudioSpec want, have;
    SDL_zero(want);
    want.freq = 48000;
    want.format = AUDIO_F32SYS;
    want.channels = 2;
    want.samples = 512;
    want.callback = audio_cb;
    dev = SDL_OpenAudioDevice(NULL, 0, &want, &have, SDL_AUDIO_ALLOW_FREQUENCY_CHANGE);
    if (!dev) {
        SDL_Log("audio disabled: %s", SDL_GetError());
        return false;
    }
    sample_rate = have.freq;
    SDL_Log("audio: %s, %d Hz", SDL_GetCurrentAudioDriver(), sample_rate);
    SDL_PauseAudioDevice(dev, 0);
    return true;
}

void audio_shutdown(void) {
    if (dev)
        SDL_CloseAudioDevice(dev);
    dev = 0;
    free_song(song);
    song = NULL;
    free_stream(stream);
    stream = NULL;
}

void audio_stop_all(void) {
    if (!dev)
        return;
    SDL_LockAudioDevice(dev);
    Song *old = song;
    Stream *olds = stream;
    song = NULL;
    stream = NULL;
    for (int i = 0; i < MAX_VOICES; i++)
        voices[i].active = false;
    for (int i = 0; i < MAX_SVOICES; i++)
        svoices[i].active = false;
    SDL_UnlockAudioDevice(dev);
    free_song(old);
    free_stream(olds);
}

/* ------------------------------------------------------------------ */
/* Lua API                                                             */
/* ------------------------------------------------------------------ */

static double num_field(lua_State *L, int t, const char *k, double def) {
    lua_getfield(L, t, k);
    double v = lua_isnumber(L, -1) ? lua_tonumber(L, -1) : def;
    lua_pop(L, 1);
    return v;
}

static int wave_field(lua_State *L, int t, const char *k, int def) {
    lua_getfield(L, t, k);
    const char *s = lua_tostring(L, -1);
    int w = def;
    if (s) {
        if (!strcmp(s, "square") || !strcmp(s, "pulse"))
            w = W_SQUARE;
        else if (!strcmp(s, "triangle") || !strcmp(s, "tri"))
            w = W_TRIANGLE;
        else if (!strcmp(s, "saw"))
            w = W_SAW;
        else if (!strcmp(s, "sine"))
            w = W_SINE;
        else if (!strcmp(s, "noise"))
            w = W_NOISE;
    }
    lua_pop(L, 1);
    return w;
}

static int l_play(lua_State *L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    if (!dev)
        return 0;
    VoiceParams p = {0};
    p.bus = BUS_SFX;
    p.wave = wave_field(L, 1, "wave", W_SQUARE);
    p.freq = num_field(L, 1, "freq", 440);
    p.freq_end = num_field(L, 1, "to", p.freq);
    p.dur = num_field(L, 1, "dur", 0.1);
    p.vol = num_field(L, 1, "vol", 0.5);
    p.pan = num_field(L, 1, "pan", 0);
    p.attack = num_field(L, 1, "attack", 0.002);
    p.release = num_field(L, 1, "release", 0.02);
    p.decay = num_field(L, 1, "decay", 0);
    p.duty = num_field(L, 1, "duty", 0.5);
    p.delay = num_field(L, 1, "delay", 0);
    p.vib_depth = num_field(L, 1, "vib", 0);
    p.vib_rate = num_field(L, 1, "vibrate", 6);
    SDL_LockAudioDevice(dev);
    voice_start(&p);
    SDL_UnlockAudioDevice(dev);
    return 0;
}

static int parse_token(const char *tok, bool drums) {
    if (drums) {
        switch (tok[0]) {
            case 'K':
                return 0;
            case 'S':
                return 1;
            case 'H':
                return 2;
            case 'O':
                return 3;
            case 'C':
                return 4;
            case 'T':
                return 5;
            default:
                return -1;
        }
    }
    static const int semis[7] = {9, 11, 0, 2, 4, 5, 7}; /* A..G */
    int c = toupper((unsigned char)tok[0]);
    if (c < 'A' || c > 'G')
        return -1;
    int n = semis[c - 'A'], i = 1;
    if (tok[i] == '#') {
        n++;
        i++;
    } else if (tok[i] == 'b') {
        n--;
        i++;
    }
    int oct = 4;
    if (isdigit((unsigned char)tok[i]))
        oct = tok[i] - '0';
    return 12 * (oct + 1) + n;
}

static void parse_channel(lua_State *L, int t, Channel *ch) {
    lua_getfield(L, t, "drums");
    ch->drums = lua_toboolean(L, -1);
    lua_pop(L, 1);
    ch->wave = wave_field(L, t, "wave", W_SQUARE);
    ch->vol = num_field(L, t, "vol", 0.3);
    ch->pan = num_field(L, t, "pan", 0);
    ch->duty = num_field(L, t, "duty", 0.5);
    ch->attack = num_field(L, t, "attack", 0.005);
    ch->release = num_field(L, t, "release", 0.03);
    ch->decay = num_field(L, t, "decay", 0);
    ch->legato = num_field(L, t, "legato", 0.9);
    ch->transpose = (int)num_field(L, t, "transpose", 0);
    ch->vib_depth = num_field(L, t, "vib", 0);
    ch->vib_rate = num_field(L, t, "vibrate", 5.5);

    lua_getfield(L, t, "notes");
    const char *s = lua_tostring(L, -1);
    if (!s)
        s = "";
    int cap = 64, n = 0, last = -1;
    Step *steps = (Step *)malloc(sizeof(Step) * (size_t)cap);
    while (*s && steps) {
        while (*s && isspace((unsigned char)*s))
            s++;
        if (!*s)
            break;
        char tok[16] = {0};
        int k = 0;
        while (*s && !isspace((unsigned char)*s)) {
            if (k < 15)
                tok[k++] = *s;
            s++;
        }
        tok[k] = '\0';
        if (!strcmp(tok, "|"))
            continue;
        if (n == cap) {
            cap *= 2;
            Step *ns = (Step *)realloc(steps, sizeof(Step) * (size_t)cap);
            if (!ns)
                break;
            steps = ns;
        }
        Step st = {-1, 0};
        if (!strcmp(tok, "-")) {
            if (last >= 0)
                steps[last].len++;
        } else if (strcmp(tok, ".") != 0) {
            st.note = parse_token(tok, ch->drums);
            st.len = 1;
            last = st.note >= 0 ? n : -1;
        } else {
            last = -1;
        }
        steps[n++] = st;
    }
    lua_pop(L, 1);
    ch->steps = steps;
    ch->nsteps = steps ? n : 0;
}

static int l_music(lua_State *L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    if (!dev)
        return 0;
    Song *s = (Song *)calloc(1, sizeof *s);
    if (!s)
        return luaL_error(L, "out of memory");
    double bpm = num_field(L, 1, "bpm", 120);
    double spb = num_field(L, 1, "spb", 4);
    if (bpm < 20)
        bpm = 20;
    if (spb < 1)
        spb = 1;
    s->samples_per_step = sample_rate * 60.0 / bpm / spb;
    s->acc = s->samples_per_step; /* first step fires immediately */
    lua_getfield(L, 1, "loop");
    s->loop = lua_isnil(L, -1) ? true : lua_toboolean(L, -1);
    lua_pop(L, 1);

    lua_getfield(L, 1, "channels");
    if (lua_istable(L, -1)) {
        int tc = lua_gettop(L);
        int n = (int)luaL_len(L, tc);
        for (int i = 1; i <= n && s->nch < MAX_CHANNELS; i++) {
            lua_rawgeti(L, tc, i);
            if (lua_istable(L, -1)) {
                Channel *ch = &s->ch[s->nch++];
                parse_channel(L, lua_gettop(L), ch);
                if (ch->nsteps > s->total_steps)
                    s->total_steps = ch->nsteps;
            }
            lua_pop(L, 1);
        }
    }
    lua_pop(L, 1);

    SDL_LockAudioDevice(dev);
    Song *old = song;
    Stream *olds = stream;
    song = s;
    stream = NULL;
    for (int i = 0; i < MAX_VOICES; i++)
        if (voices[i].bus == BUS_MUSIC)
            voices[i].active = false;
    SDL_UnlockAudioDevice(dev);
    free_song(old);
    free_stream(olds);
    return 0;
}

static int l_stop_music(lua_State *L) {
    (void)L;
    if (!dev)
        return 0;
    SDL_LockAudioDevice(dev);
    Song *old = song;
    Stream *olds = stream;
    song = NULL;
    stream = NULL;
    for (int i = 0; i < MAX_VOICES; i++)
        if (voices[i].bus == BUS_MUSIC)
            voices[i].active = false;
    SDL_UnlockAudioDevice(dev);
    free_song(old);
    free_stream(olds);
    return 0;
}

static int l_stop(lua_State *L) {
    (void)L;
    audio_stop_all();
    return 0;
}

/* audio.volume(master, sfx, music) -- any may be nil; 0..1 */
static int l_volume(lua_State *L) {
    if (dev)
        SDL_LockAudioDevice(dev);
    if (lua_isnumber(L, 1))
        master_vol = (float)lua_tonumber(L, 1);
    if (lua_isnumber(L, 2))
        sfx_vol = (float)lua_tonumber(L, 2);
    if (lua_isnumber(L, 3))
        music_vol = (float)lua_tonumber(L, 3);
    if (dev)
        SDL_UnlockAudioDevice(dev);
    lua_pushnumber(L, master_vol);
    lua_pushnumber(L, sfx_vol);
    lua_pushnumber(L, music_vol);
    return 3;
}

/* audio.load(path) -> Sample | nil, err */
static int l_load(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    size_t len = 0;
    unsigned char *file = (unsigned char *)fs_read(path, &len);
    if (!file) {
        lua_pushnil(L);
        lua_pushfstring(L, "cannot read %s", path);
        return 2;
    }
    char err[512] = "";
    Pcm *p = decode_pcm(file, len, path, err, sizeof err);
    free(file);
    if (!p) {
        lua_pushnil(L);
        lua_pushstring(L, err);
        return 2;
    }
    SampleUD *ud = (SampleUD *)lua_newuserdatauv(L, sizeof *ud, 0);
    ud->pcm = p;
    luaL_setmetatable(L, SAMPLE_MT);
    return 1;
}

static int l_sample_gc(lua_State *L) {
    SampleUD *ud = (SampleUD *)luaL_checkudata(L, 1, SAMPLE_MT);
    if (!ud->pcm)
        return 0;
    if (dev)
        SDL_LockAudioDevice(dev);
    for (int i = 0; i < MAX_SVOICES; i++)
        if (svoices[i].pcm == ud->pcm)
            svoices[i].active = false;
    if (dev)
        SDL_UnlockAudioDevice(dev);
    free_pcm(ud->pcm);
    ud->pcm = NULL;
    return 0;
}

static int l_sample_duration(lua_State *L) {
    SampleUD *ud = (SampleUD *)luaL_checkudata(L, 1, SAMPLE_MT);
    lua_pushnumber(L, ud->pcm ? (double)ud->pcm->frames / sample_rate : 0.0);
    return 1;
}

/* audio.play_sample(sample [, vol [, pan [, pitch]]]) */
static int l_play_sample(lua_State *L) {
    SampleUD *ud = (SampleUD *)luaL_checkudata(L, 1, SAMPLE_MT);
    double vol = luaL_optnumber(L, 2, 1.0);
    double pan = luaL_optnumber(L, 3, 0.0);
    double pitch = luaL_optnumber(L, 4, 1.0);
    if (!dev || !ud->pcm || ud->pcm->frames == 0)
        return 0;
    if (pan < -1)
        pan = -1;
    if (pan > 1)
        pan = 1;
    if (pitch < 0.1)
        pitch = 0.1;
    SDL_LockAudioDevice(dev);
    SampleVoice *v = NULL;
    unsigned best = 0;
    for (int i = 0; i < MAX_SVOICES; i++) {
        if (!svoices[i].active) {
            v = &svoices[i];
            break;
        }
        unsigned age = age_counter - svoices[i].age;
        if (!v || age > best) {
            best = age;
            v = &svoices[i];
        }
    }
    v->active = true;
    v->pcm = ud->pcm;
    v->pos = 0.0;
    v->step = pitch;
    v->gl = (float)(vol * (pan > 0 ? 1.0 - pan : 1.0));
    v->gr = (float)(vol * (pan < 0 ? 1.0 + pan : 1.0));
    v->age = age_counter++;
    SDL_UnlockAudioDevice(dev);
    return 0;
}

/* audio.music_file(path [, opts]) -> true | nil, err */
static int l_music_file(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    bool loop = true;
    double loop_start = 0.0, vol = 1.0;
    if (lua_istable(L, 2)) {
        lua_getfield(L, 2, "loop");
        if (!lua_isnil(L, -1))
            loop = lua_toboolean(L, -1);
        lua_pop(L, 1);
        loop_start = num_field(L, 2, "loop_start", 0.0);
        vol = num_field(L, 2, "volume", 1.0);
    }
    if (!dev) {
        lua_pushboolean(L, 1);
        return 1;
    }
    size_t len = 0;
    unsigned char *file = (unsigned char *)fs_read(path, &len);
    if (!file) {
        lua_pushnil(L);
        lua_pushfstring(L, "cannot read %s", path);
        return 2;
    }
    Stream *st = (Stream *)calloc(1, sizeof *st);
    if (!st) {
        free(file);
        return luaL_error(L, "out of memory");
    }
    st->loop = loop;
    st->vol = (float)vol;
    if (is_ogg(file, len)) {
        int e = 0;
        st->vorb = stb_vorbis_open_memory(file, (int)len, &e, NULL);
        if (!st->vorb) {
            free(file);
            free(st);
            lua_pushnil(L);
            lua_pushfstring(L, "%s: cannot open OGG (error %d)", path, e);
            return 2;
        }
        stb_vorbis_info info = stb_vorbis_get_info(st->vorb);
        st->file = file; /* must outlive the decoder */
        st->channels = info.channels;
        st->rate = (int)info.sample_rate;
        st->step = (double)st->rate / sample_rate;
        st->loop_start_src = (unsigned)(loop_start * st->rate);
        if (!ogg_pull(st, st->a) || !ogg_pull(st, st->b))
            st->finished = true;
    } else {
        char err[512] = "";
        st->pcm = decode_pcm(file, len, path, err, sizeof err);
        free(file);
        if (!st->pcm) {
            free(st);
            lua_pushnil(L);
            lua_pushstring(L, err);
            return 2;
        }
        st->loop_start_pcm = (int)(loop_start * sample_rate);
    }
    SDL_LockAudioDevice(dev);
    Song *old = song;
    Stream *olds = stream;
    song = NULL;
    stream = st;
    for (int i = 0; i < MAX_VOICES; i++)
        if (voices[i].bus == BUS_MUSIC)
            voices[i].active = false;
    SDL_UnlockAudioDevice(dev);
    free_song(old);
    free_stream(olds);
    lua_pushboolean(L, 1);
    return 1;
}

static int l_enabled(lua_State *L) {
    lua_pushboolean(L, dev != 0);
    return 1;
}

int luaopen_audio(lua_State *L) {
    static const luaL_Reg sample_methods[] = {{"duration", l_sample_duration}, {NULL, NULL}};
    luaL_newmetatable(L, SAMPLE_MT);
    lua_pushcfunction(L, l_sample_gc);
    lua_setfield(L, -2, "__gc");
    luaL_newlib(L, sample_methods);
    lua_setfield(L, -2, "__index");
    lua_pop(L, 1);

    static const luaL_Reg fns[] = {
        {"play", l_play},
        {"music", l_music},
        {"stop_music", l_stop_music},
        {"stop", l_stop},
        {"volume", l_volume},
        {"enabled", l_enabled},
        {"load", l_load},
        {"play_sample", l_play_sample},
        {"music_file", l_music_file},
        {NULL, NULL},
    };
    luaL_newlib(L, fns);
    return 1;
}
