AAR_OUT     = ../client/android/libs/rnsbind.aar
UNITY_JDK   = /home/ars/Unity/Hub/Editor/6000.3.8f1/Editor/Data/PlaybackEngines/AndroidPlayer/OpenJDK/bin
NDK         = /media/ars/Storage-1t/android-sdk/ndk/28.2.13676358

.PHONY: build clean deps

deps:
	go mod tidy

build: deps
	PATH="$(UNITY_JDK):$$PATH" \
	ANDROID_NDK_HOME=$(NDK) \
	gomobile bind -target=android/arm64 -androidapi 21 -o $(AAR_OUT)
	@echo "Built $(AAR_OUT)"

clean:
	rm -f $(AAR_OUT) $(AAR_OUT:.aar=-sources.jar)
