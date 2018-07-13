time for f in *.jpg; do convert $f -canny 0x1+10%+30% out/$f; done
