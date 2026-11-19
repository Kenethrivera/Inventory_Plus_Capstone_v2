-dontwarn java.beans.**
-dontwarn org.yaml.snakeyaml.**

# Ignore all missing optional TensorFlow Lite core, GPU, and NNAPI classes
-dontwarn org.tensorflow.lite.**

# Keep TensorFlow Lite classes from being stripped by R8
-keep class org.tensorflow.lite.** { *; }