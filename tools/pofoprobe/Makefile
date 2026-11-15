# Build on the Raspberry Pi (needs wiringPi). Installs to ~/pofoprobe,
# never over rpfolio.

CFLAGS ?= -O2 -Wall -Wextra

pofoprobe: pofoprobe.c
	$(CC) $(CFLAGS) -o $@ $< -lwiringPi

install: pofoprobe
	cp pofoprobe $(HOME)/pofoprobe

clean:
	rm -f pofoprobe

.PHONY: install clean
