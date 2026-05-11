CC ?= gcc
CFLAGS ?= -O2 -Wall

all: qmi-dtr mcu-proto

qmi-dtr: qmi-dtr.c
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $<

mcu-proto: mcu-proto.c
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $<

clean:
	rm -f qmi-dtr mcu-proto

.PHONY: all clean
