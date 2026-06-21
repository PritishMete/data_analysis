cd G:\data_analyst
flutter build web --base-href /data_analysis/
cd build\web
git add .
git commit -m "Deploy Flutter web"
git remote remove origin
git remote add origin https://github.com/PritishMete/data_analysis.git
git push -f origin gh-pages --force




# 1. Navigate back to the main project directory root
cd G:\data_analyst

# 2. Compile a fresh production web bundle with your base-href configured
flutter build web --base-href /data_analysis/

# 3. Enter the target web build folder
cd build\web

# 4. Initialize Git locally inside build\web if needed, or link the remote
git init
git remote remove origin
git remote add origin https://github.com/PritishMete/data_analysis.git

# 5. CRITICAL FIX: Force add all build files (bypasses the .gitignore restriction)
git add . --force

# 6. Commit the newly staged files
git commit -m "Deploy production web assets to gh-pages"

# 7. Check out to or force create the gh-pages branch locally
git branch -M gh-pages

# 8. Force push the clean web files up to your GitHub hosting branch
git push -f origin gh-pages