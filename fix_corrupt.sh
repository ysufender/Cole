rm -rf .git/
cd ..
git clone https://codeberg.org/ysufender/Cole.git Cole_COPY
mv Cole_COPY/.git Cole/
rm -rf Cole_COPY
cd Cole
git stat

