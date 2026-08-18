CC = clang
CFLAGS = -O2 -g -Wall -target bpf

all: xdp_eap.o xdp_radius.o

xdp_eap.o: xdp_eap.c
	$(CC) $(CFLAGS) -c xdp_eap.c -o xdp_eap.o

xdp_radius.o: xdp_radius.c
	$(CC) $(CFLAGS) -c xdp_radius.c -o xdp_radius.o

clean:
	rm -f *.o
