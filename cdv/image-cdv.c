/*

TODO (in this order):

- code 4 functions for cdv and define cdv output format and output channel
  + histogram: DONE
  + texture: TODO
  + contour: TODO
  + directions: TODO
- establish my own error handler for jpeg_decompress (see /usr/share/doc/packages/libjpeg62-devel/example.c)
- catch errors on malloc
- prepare for component range not [0..255] (>8bit)
- add png parser

*/

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <jpeglib.h>

const int alignment = 4;

struct image_blob {
    int width;
    int height;
    int components;
    size_t size;
    unsigned short int *buffer;
};

GLOBAL(int) read_JPEG_file (char * filename, struct image_blob * blob)
{
    struct jpeg_decompress_struct cinfo;
    struct jpeg_error_mgr jerr;
    FILE * infile;
    JSAMPARRAY buffer;
    int row_stride;
    unsigned short int *blob_pixels;
    unsigned char* buffer_pixels;

    /* setup the decompressing */

    if ((infile = fopen(filename, "rb")) == NULL) {
	fprintf(stderr, "can't open %s\n", filename);
	return EXIT_FAILURE;
    }

    cinfo.err = jpeg_std_error(&jerr);
    jpeg_create_decompress(&cinfo);
    jpeg_stdio_src(&cinfo, infile);

    (void) jpeg_read_header(&cinfo, TRUE);
    (void) jpeg_start_decompress(&cinfo);

    /* prepare to repack the bits into data types better aligned for up2date processors */

    blob->width = cinfo.output_width;
    blob->height = cinfo.output_height;
    blob->components = cinfo.output_components;
    blob->size = blob->width * blob->height * sizeof(unsigned short int) * alignment;
    blob->buffer = (unsigned short int *) malloc (blob->size);
    if (! blob->buffer) {
	fprintf(stderr, "unable to allocate memory for image %s\n", filename);
	(void) jpeg_finish_decompress(&cinfo);
	jpeg_destroy_decompress(&cinfo);
	fclose(infile);
    }
    printf("DEBUG: %s, image dimensions %d x %d, %d components, allocated %0.1f MB\n", 
	    filename, blob->width, blob->height, blob->components, (float) blob->size/1048576);

    /* read and repack the bits */

    row_stride = cinfo.output_width * cinfo.output_components;
    buffer = (*cinfo.mem->alloc_sarray) ((j_common_ptr) &cinfo, JPOOL_IMAGE, row_stride, 1);

    blob_pixels = blob-> buffer;
    while (cinfo.output_scanline < cinfo.output_height) {
	(void) jpeg_read_scanlines(&cinfo, buffer, 1);
	buffer_pixels = buffer[0]; 
	int n = blob->width;
	while (n--) {
	    int c = blob->components;
	    while (c--) {
		*blob_pixels++ = *buffer_pixels++;
	    }
	    blob_pixels += (alignment - blob->components);
	}
    }

    /* cleanup */

    (void) jpeg_finish_decompress(&cinfo);
    jpeg_destroy_decompress(&cinfo);
    fclose(infile);

    return EXIT_SUCCESS;
}


int write_TGA_file (char * filename, struct image_blob * blob)
{
    unsigned char header[18];
    FILE *fp;

    fp = fopen(filename,"wb");

    if (fp) {
	/* http://de.wikipedia.org/wiki/Targa_Image_File */

	header[0] = 0; /* idlen */
	header[1] = 0; /* cmtype */
	header[2] = (blob->components == 3) ? 2 : (blob->components == 1) ? 3 : 0; /* itype */
	header[3] = header[4] = 0; /* cmorg */
	header[5] = header[6] = 0; /* cmlen */
	header[7] = 24; /* cmesize */
	header[8] = header[9] = 0; /* xorg */
	header[10] = header[11] = 0; /* yorg */
	header[12] = blob->width % 256; header[13] = blob->width/256;
	header[14] = blob->height % 256; header[15] = blob->height/256;
	header[16] = blob->components * 8; /* bpp */
	header[17] = 1<<5; /* ides */
	fwrite(header, 18, 1, fp);

	unsigned short int *blob_pixels = blob->buffer;
	unsigned char *buffer = (unsigned char*) malloc(blob->components * blob->width);
	int c = blob->components;

	int m = blob->height;
	while (m--) {
	    unsigned char *dst = buffer;
	    int n = blob->width;
	    while (n--) {
		if (c == 3) { /* TGA uses BGR(A) instead of RGB(A) ! */
		    *(dst+2) = *blob_pixels++; /* component red */
		    *(dst+1) = *blob_pixels++; /* component green */
		    *dst = *blob_pixels++;     /* component blue */
		    dst += 3;
		}
		else if (c == 1) {
		    *dst++ = *blob_pixels++;
		}
		blob_pixels += (alignment - blob->components);
	    }
	    fwrite(buffer, blob->components, blob->width, fp);
	}

	free (buffer);
    }
    else {
	fprintf(stderr,"could not open \"%s\"!\n", filename);
	return EXIT_FAILURE;
    }

    return EXIT_SUCCESS;
}


int histogram (struct image_blob * blob)
{
    unsigned int red_hist [256];
    unsigned int green_hist [256];
    unsigned int blue_hist [256];
    unsigned int gray_hist [256];

    unsigned short int *blob_pixels = blob->buffer;
    int c = blob->components;

    memset(red_hist, 0, 256 * sizeof(unsigned int));
    memset(green_hist, 0, 256 * sizeof(unsigned int));
    memset(blue_hist, 0, 256 * sizeof(unsigned int));
    memset(gray_hist, 0, 256 * sizeof(unsigned int));

    int m = blob->height;
    while (m--) {
	int n = blob->width;
	while (n--) {
	    if (c == 3) {
		unsigned char r = *blob_pixels++;
		unsigned char g = *blob_pixels++;
		unsigned char b = *blob_pixels++;
		unsigned char gray = (float)r * 0.299 + (float)g * 0.587 + (float)b * 0.114;
		red_hist[r]++;
		green_hist[g]++;
		blue_hist[b]++;
		gray_hist[gray]++;
    	    }
	    else if (c == 1) {
		gray_hist[*blob_pixels++]++;
	    }
	    blob_pixels += (alignment - blob->components);
	}
    }

    printf("[HISTOGRAMS]\n\n");
    if (c==3) { printf("value, red, green, blue, gray\n"); }
    else { printf("value, gray\n"); }

    unsigned int red_max = 0;
    unsigned int green_max = 0;
    unsigned int blue_max = 0;
    unsigned int gray_max = 0;
    int i;

    for (i=0; i<256; i++) {
	if (red_hist[i] > red_max) { red_max = red_hist[i]; }	
	if (green_hist[i] > green_max) { green_max = green_hist[i]; }	
	if (blue_hist[i] > blue_max) { blue_max = blue_hist[i]; }	
	if (gray_hist[i] > gray_max) { gray_max = gray_hist[i]; }	
    }

    for (i=0; i<256; i++) {
	printf ("%u, ", i);
	if (c == 3) {
	    printf ("%0.3f, %0.3f, %0.3f, ", 
		    (double) red_hist[i]/(double) red_max,
		    (double) green_hist[i]/(double) green_max,
		    (double) blue_hist[i]/(double) blue_max);
	}
	printf ("%0.3f\n", (double) gray_hist[i]/(double) gray_max);
    }

    return EXIT_SUCCESS;
}

int main (int argc, char *argv[])
{
    struct image_blob blob;
    int num_fails = 0;

    int n = 1;
    while (n<argc) {
	int result = read_JPEG_file(argv[n], &blob);
	if (result == EXIT_FAILURE) { 
	    printf ("ERROR in read_JPEG_file (%s, ...)\n", argv[n]); 
	    num_fails++;
	}
	else {
	    int x = blob.width/2;
	    int y = blob.height/2;
	    unsigned short int r = *(blob.buffer + (x + y*blob.width) * alignment + 0);
	    unsigned short int g = *(blob.buffer + (x + y*blob.width) * alignment + 1);
	    unsigned short int b = *(blob.buffer + (x + y*blob.width) * alignment + 2);
	    printf ("DEBUG: %s, values at x=%d, y=%d: ", argv[n],  x, y);
	    if (blob.components == 3) { printf ("r=%u, g=%u, b=%u\n", r, g, b); }
	    else if (blob.components == 1) { printf ("v=%u\n", r); }

	    char *tganame = (char*) malloc(strlen(argv[n])+4+1);
	    strcpy(tganame, argv[n]);
	    strcat(tganame + strlen(argv[n]), ".tga");
	    write_TGA_file(tganame, &blob);
	    printf("DEBUG: dumped in-memory image to %s\n", tganame);
	    free(tganame);

	    histogram (&blob);

	    free(blob.buffer);
	}
	n++;
    }

    return num_fails;
}

