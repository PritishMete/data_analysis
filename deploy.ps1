cd G:\data_analyst
flutter build web --base-href /data_analysis/
cd build\web
git add .
git commit -m "Deploy Flutter web"
git remote remove origin
git remote add origin https://github.com/PritishMete/data_analysis.git
git push -f origin gh-pages --force