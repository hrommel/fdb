
CC=gcc
CFLAGS=-Wall -g -O2 -mtune=native

all:	image-cdv
	
clean:
	rm -f image-cdv

image-cdv: image-cdv.c
	$(CC) $(CFLAGS) -ljpeg $< -o $@

