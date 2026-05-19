rm -rf .git/
cd ..
git clone https://codeberg.org/ysufender/JASL.git JASL_COPY
mv JASL_COPY/.git JASL/
rm -rf JASL_COPY
cd JASL
git stat
