NASM ?= nasm

all: SERVER.COM MKFIX.COM

SERVER.COM: src/server.asm
	$(NASM) -f bin -w+all -w-reloc-abs-word -o $@ -l server.lst $<

clean:
	rm -f SERVER.COM server.lst MKFIX.COM

.PHONY: all clean

# Test fixture builder (see tests/README.md)
MKFIX.COM: tests/fixtures/mkfix.asm
	$(NASM) -f bin -w+all -w-reloc-abs-word -o $@ $<
