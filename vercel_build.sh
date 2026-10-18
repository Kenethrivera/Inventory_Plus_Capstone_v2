#!/bin/bash

# 1. Generate the .env file using Vercel's environment variables
echo "SUPABASE_URL=$SUPABASE_URL" > lib/.env
echo "SUPABASE_ANON_KEY=$SUPABASE_ANON_KEY" >> lib/.env
echo "GROQ_API_KEY=$GROQ_API_KEY" >> lib/.env
echo "GROQ_API_KEY_OBJ=$GROQ_API_KEY_OBJ" >> lib/.env
echo "GEMINI_API_KEY_1=$GEMINI_API_KEY_1" >> lib/.env
echo "GEMINI_API_KEY_2=$GEMINI_API_KEY_2" >> lib/.env
echo "GEMINI_API_KEY_3=$GEMINI_API_KEY_3" >> lib/.env
echo "GEMINI_API_KEY_4=$GEMINI_API_KEY_4" >> lib/.env
echo "GEMINI_API_KEY_5=$GEMINI_API_KEY_5" >> lib/.env

# 2. Run the Flutter web build. Icon tree shaking is intentionally enabled.
flutter/bin/flutter build web --release

# 3. lucide_icons_flutter registers every optional weight in its package
# manifest even when the app imports only the regular library. Remove those
# unused web font families from the generated manifest and deployment output.
flutter/bin/dart tool/prune_web_fonts.dart
