#include <jni.h>
#include <fluidsynth.h>
#include <unistd.h>
#include <map>

std::map<int, fluid_synth_t*> synths = {};
std::map<int, fluid_audio_driver_t*> drivers = {};
std::map<int, fluid_settings_t*> settings = {};
std::map<int, int> soundfonts = {};
int nextSfId = 1;

namespace {
fluid_synth_t* findSynth(int sfId) {
    auto it = synths.find(sfId);
    return it != synths.end() ? it->second : nullptr;
}

fluid_audio_driver_t* findDriver(int sfId) {
    auto it = drivers.find(sfId);
    return it != drivers.end() ? it->second : nullptr;
}

fluid_settings_t* findSettings(int sfId) {
    auto it = settings.find(sfId);
    return it != settings.end() ? it->second : nullptr;
}

int findSoundfont(int sfId) {
    auto it = soundfonts.find(sfId);
    return it != soundfonts.end() ? it->second : -1;
}
}

extern "C" JNIEXPORT int JNICALL
Java_com_melihhakanpektas_flutter_1midi_1pro_FlutterMidiProPlugin_loadSoundfont(JNIEnv* env, jclass clazz, jstring path, jint bank, jint program) {
    settings[nextSfId] = new_fluid_settings();
    fluid_settings_setnum(settings[nextSfId], "synth.gain", 1.0);
    // sayısal değerleri uygun setter ile ayarla
    fluid_settings_setint(settings[nextSfId], "audio.period-size", 64);
    fluid_settings_setint(settings[nextSfId], "audio.periods", 4);
    fluid_settings_setint(settings[nextSfId], "audio.realtime-prio", 99);
    fluid_settings_setnum(settings[nextSfId], "synth.sample-rate", 44100.0);
    fluid_settings_setint(settings[nextSfId], "synth.polyphony", 32);

    const char *nativePath = env->GetStringUTFChars(path, nullptr);
    synths[nextSfId] = new_fluid_synth(settings[nextSfId]);
    int sfId = fluid_synth_sfload(synths[nextSfId], nativePath, 0);
    for (int i = 0; i < 16; i++) {
        fluid_synth_program_select(synths[nextSfId], i, sfId, bank, program);
    }
    env->ReleaseStringUTFChars(path, nativePath);
    // Audio driver'ı en son oluştur
    drivers[nextSfId] = new_fluid_audio_driver(settings[nextSfId], synths[nextSfId]);
    soundfonts[nextSfId] = sfId;
    nextSfId++;
    return nextSfId - 1;
}

extern "C" JNIEXPORT void JNICALL
Java_com_melihhakanpektas_flutter_1midi_1pro_FlutterMidiProPlugin_selectInstrument(JNIEnv* env, jclass clazz, jint sfId, jint channel, jint bank, jint program) {
    fluid_synth_t* synth = findSynth(sfId);
    int soundfont = findSoundfont(sfId);
    if (synth == nullptr || soundfont == -1) return;
    fluid_synth_program_select(synth, channel, soundfont, bank, program);
}

extern "C" JNIEXPORT void JNICALL
Java_com_melihhakanpektas_flutter_1midi_1pro_FlutterMidiProPlugin_playNote(JNIEnv* env, jclass clazz, jint channel, jint key, jint velocity, jint sfId) {
    fluid_synth_t* synth = findSynth(sfId);
    if (synth == nullptr) return;
    fluid_synth_noteon(synth, channel, key, velocity);
}

extern "C" JNIEXPORT void JNICALL
Java_com_melihhakanpektas_flutter_1midi_1pro_FlutterMidiProPlugin_stopNote(JNIEnv* env, jclass clazz, jint channel, jint key, jint sfId) {
    fluid_synth_t* synth = findSynth(sfId);
    if (synth == nullptr) return;
    fluid_synth_noteoff(synth, channel, key);
}

extern "C" JNIEXPORT void JNICALL
Java_com_melihhakanpektas_flutter_1midi_1pro_FlutterMidiProPlugin_stopAllNotes(JNIEnv* env, jclass clazz, jint sfId) {
    fluid_synth_t* synth = findSynth(sfId);
    if (synth == nullptr) return;
    // Sustain'i kapat ve tüm kanallar için All Sound Off gönder
    for (int ch = 0; ch < 16; ++ch) {
        fluid_synth_cc(synth, ch, 64, 0); // Sustain off
        fluid_synth_all_sounds_off(synth, ch); // Instant cut
    }
}

extern "C" JNIEXPORT void JNICALL
Java_com_melihhakanpektas_flutter_1midi_1pro_FlutterMidiProPlugin_controlChange(JNIEnv* env, jclass clazz, jint sfId, jint channel, jint controller, jint value) {
    fluid_synth_t* synth = findSynth(sfId);
    if (synth == nullptr) return;
    fluid_synth_cc(synth, channel, controller, value);
}

extern "C" JNIEXPORT void JNICALL
Java_com_melihhakanpektas_flutter_1midi_1pro_FlutterMidiProPlugin_unloadSoundfont(JNIEnv* env, jclass clazz, jint sfId) {
    fluid_audio_driver_t* driver = findDriver(sfId);
    fluid_synth_t* synth = findSynth(sfId);
    fluid_settings_t* sfSettings = findSettings(sfId);

    if (driver != nullptr) {
        delete_fluid_audio_driver(driver);
    }
    if (synth != nullptr) {
        delete_fluid_synth(synth);
    }
    if (sfSettings != nullptr) {
        delete_fluid_settings(sfSettings);
    }

    synths.erase(sfId);
    drivers.erase(sfId);
    settings.erase(sfId);
    soundfonts.erase(sfId);
}

extern "C" JNIEXPORT void JNICALL
Java_com_melihhakanpektas_flutter_1midi_1pro_FlutterMidiProPlugin_dispose(JNIEnv* env, jclass clazz) {
    for (auto const& x : synths) {
        fluid_audio_driver_t* driver = findDriver(x.first);
        fluid_settings_t* sfSettings = findSettings(x.first);
        if (driver != nullptr) {
            delete_fluid_audio_driver(driver);
        }
        if (x.second != nullptr) {
            delete_fluid_synth(x.second);
        }
        if (sfSettings != nullptr) {
            delete_fluid_settings(sfSettings);
        }
    }
    synths.clear();
    drivers.clear();
    settings.clear();
    soundfonts.clear();
}
