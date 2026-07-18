cd G:\data_analyst
flutter build web --base-href /data_analysis/
cd build\web
git add .
git commit -m "Deploy Flutter web"
git remote remove origin
git remote add origin https://github.com/PritishMete/data_analysis.git
git push -f origin gh-pages --force

cd G:\data_analyst
flutter build web --base-href /data_analysis/
cd build\web
git init
git remote remove origin
git remote add origin https://github.com/PritishMete/data_analysis.git
git add . --force
git commit -m "Deploy production web assets to gh-pages"
git branch -M gh-pages
git push -f origin gh-pages