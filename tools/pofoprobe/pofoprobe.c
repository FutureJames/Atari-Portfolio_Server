/*
  pofoprobe - raw protocol probe for the Atari Portfolio file transfer server

  Sends and receives single blocks over the Portfolio's parallel port
  protocol, as scripted, and logs every byte. Unlike transfolio / rpfolio it
  never exits on an unexpected byte and never hangs: each wait for a clock
  edge times out, the step is logged as failed, and the script goes on.

  The bit- and block-level code follows transfolio.c (Klaus Peichl,
  github.com/skudi/transfolio, commit ab89073) with its RASPIWIRING pins
  and the same delays, so the Portfolio sees the same timing as from rpfolio.

  Build (on the Pi):  cc -O2 -Wall -o pofoprobe pofoprobe.c -lwiringPi
  Run:                ./pofoprobe SCRIPT      (or - for stdin)

  See README.md in this folder for the script language.
*/

#define _DEFAULT_SOURCE   /* usleep, nanosleep, clock_gettime */

#include <ctype.h>
#include <errno.h>
#include <setjmp.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <wiringPi.h>

/* wiringPi pin numbers, as transfolio's RASPIWIRING build */
static const int pinClkOut = 7;  /* GPIO04, header pin 7  */
static const int pinBitOut = 0;  /* GPIO17, header pin 11 */
static const int pinClkIn  = 2;  /* GPIO27, header pin 13 */
static const int pinBitIn  = 3;  /* GPIO22, header pin 15 */

#define MAX_BLOCK 65535
#define MAX_LINE  4096

static unsigned char block[MAX_BLOCK + 1];
static unsigned char rxbuf[MAX_BLOCK + 1];

static long edgeTimeoutMs = 5000;   /* per clock edge, see "timeout" */
static struct timespec deadline;
static jmp_buf stepFailed;
static char failReason[200];
static int byteIndex;               /* position within the block, for errors */
static int errors;
static int verboseTiming;

/* ------------------------------------------------------------------------ */
/* Output                                                                    */
/* ------------------------------------------------------------------------ */

static void fail(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(failReason, sizeof failReason, fmt, ap);
	va_end(ap);
	longjmp(stepFailed, 1);
}

/* FNV-1a, so big data blocks can be compared without dumping them */
static uint32_t fnv1a(const unsigned char *p, int n)
{
	uint32_t h = 2166136261u;
	while (n--) {
		h ^= *p++;
		h *= 16777619u;
	}
	return h;
}

/* hex, then the printable characters, of up to max bytes (all if max < 0) */
static void dump(const unsigned char *p, int n, int max)
{
	int shown = (max < 0 || n <= max) ? n : max;
	int i;
	for (i = 0; i < shown; i++)
		printf(" %02X", p[i]);
	if (shown < n)
		printf(" ...");
	printf("  |");
	for (i = 0; i < shown; i++)
		putchar(isprint(p[i]) ? p[i] : '.');
	printf("%s|", shown < n ? "..." : "");
}

static double nowMs(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec * 1000.0 + t.tv_nsec / 1e6;
}

/* ------------------------------------------------------------------------ */
/* Bit level (transfolio's readPort / writePort / receiveByte / sendByte)    */
/* ------------------------------------------------------------------------ */

static void armDeadline(void)
{
	clock_gettime(CLOCK_MONOTONIC, &deadline);
	deadline.tv_sec += edgeTimeoutMs / 1000;
	deadline.tv_nsec += (edgeTimeoutMs % 1000) * 1000000L;
	if (deadline.tv_nsec >= 1000000000L) {
		deadline.tv_sec++;
		deadline.tv_nsec -= 1000000000L;
	}
}

static int pastDeadline(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec > deadline.tv_sec ||
		(t.tv_sec == deadline.tv_sec && t.tv_nsec > deadline.tv_nsec);
}

static inline int clockIn(void) { return digitalRead(pinClkIn); }
static inline int bitIn(void)   { return digitalRead(pinBitIn); }

static inline void writePort(int value)
{
	digitalWrite(pinBitOut, value & 1);
	digitalWrite(pinClkOut, (value >> 1) & 1);
}

static void waitClock(int level, const char *what)
{
	unsigned n = 0;
	armDeadline();
	while (clockIn() != level) {
		if ((++n & 0xFF) == 0 && pastDeadline())
			fail("timeout waiting for clock %s (%s, byte %d)",
			     level ? "high" : "low", what, byteIndex);
	}
}

static unsigned char receiveByte(void)
{
	unsigned char byte = 0;
	int i;
	for (i = 0; i < 4; i++) {
		waitClock(0, "receiving");
		byte = (byte << 1) | bitIn();
		writePort(0);
		waitClock(1, "receiving");
		byte = (byte << 1) | bitIn();
		writePort(2);
	}
	return byte;
}

static void sendByte(unsigned char byte)
{
	struct timespec t = { 0, 50000 };
	int i, b;
	nanosleep(&t, NULL);
	for (i = 0; i < 4; i++) {
		b = (byte & 0x80) >> 7;
		writePort(b | 2);
		writePort(b);
		byte <<= 1;
		waitClock(0, "sending");

		b = (byte & 0x80) >> 7;
		writePort(b);
		writePort(b | 2);
		byte <<= 1;
		waitClock(1, "sending");
	}
}

/* ------------------------------------------------------------------------ */
/* Block level (transfolio's sendBlock / receiveBlock, logging not exiting)  */
/* ------------------------------------------------------------------------ */

static void stepSend(int len)
{
	unsigned char byte, checksum = 0;
	int i;

	printf("> send %d:", len);
	dump(block, len, 96);
	printf("\n");
	fflush(stdout);

	byteIndex = -1;
	byte = receiveByte();
	if (byte != 0x5A)
		fail("expected 5A (ready), got %02X", byte);

	usleep(50000);
	sendByte(0xA5);
	sendByte(len & 0xFF);         checksum -= len & 0xFF;
	sendByte((len >> 8) & 0xFF);  checksum -= (len >> 8) & 0xFF;
	for (i = 0; i < len; i++) {
		byteIndex = i;
		sendByte(block[i]);
		checksum -= block[i];
	}
	byteIndex = len;
	sendByte(checksum);

	byte = receiveByte();
	if (byte == checksum)
		printf("  ok, checksum %02X echoed\n", checksum);
	else {
		printf("  ! checksum %02X, echoed %02X\n", checksum, byte);
		errors++;
	}
}

static void stepRecv(int maxLen, int dumpMax, const char *savePath)
{
	unsigned char byte, lenL, lenH, sum = 0;
	int len, i;

	byteIndex = -1;
	sendByte(0x5A);
	byte = receiveByte();
	if (byte != 0xA5)
		fail("expected A5 (block start), got %02X", byte);

	lenL = receiveByte();  sum += lenL;
	lenH = receiveByte();  sum += lenH;
	len = (lenH << 8) | lenL;

	for (i = 0; i < len; i++) {
		byteIndex = i;
		rxbuf[i] = receiveByte();
		sum += rxbuf[i];
	}
	byteIndex = len;
	byte = receiveByte();

	printf("< recv %d fnv=%08X:", len, fnv1a(rxbuf, len));
	dump(rxbuf, len, dumpMax);
	printf("\n");
	if ((unsigned char)(256 - byte) == sum)
		printf("  ok, checksum %02X\n", byte);
	else {
		printf("  ! checksum %02X, expected %02X\n", byte, (unsigned char)(256 - sum));
		errors++;
	}
	if (len > maxLen) {
		printf("  ! %d bytes is more than max=%d\n", len, maxLen);
		errors++;
	}

	usleep(100);
	sendByte((unsigned char)(256 - sum));   /* as transfolio, even if wrong */

	if (savePath) {
		FILE *f = fopen(savePath, "ab");
		if (!f || fwrite(rxbuf, 1, len, f) != (size_t)len) {
			printf("  ! cannot write %s: %s\n", savePath, strerror(errno));
			errors++;
		}
		if (f)
			fclose(f);
	}
}

/* transfolio's start-up: wait for the server's 5A, nudging the clock */
static void stepSync(void)
{
	unsigned char byte;
	int skipped = 0;

	byteIndex = -1;
	writePort(2);
	waitClock(1, "sync");
	byte = receiveByte();
	while (byte != 0x5A) {
		if (++skipped > 1000)
			fail("no 5A after 1000 bytes");
		waitClock(0, "sync");
		writePort(0);
		waitClock(1, "sync");
		writePort(2);
		byte = receiveByte();
	}
	printf("= sync ok");
	if (skipped)
		printf(", %d other bytes first", skipped);
	printf("\n");
}

/* Just read whatever the server is sending: e.g. "5A" when it is idle. */
static void stepPeek(int count)
{
	int i;
	printf("= peek:");
	byteIndex = -1;
	for (i = 0; i < count; i++) {
		byteIndex = i;
		printf(" %02X", receiveByte());
		fflush(stdout);
	}
	printf("\n");
}

/* ------------------------------------------------------------------------ */
/* Script                                                                    */
/* ------------------------------------------------------------------------ */

/* next token; a quoted string is one token, quotes kept */
static char *nextToken(char **p)
{
	char *s = *p, *start;
	while (*s && isspace((unsigned char)*s))
		s++;
	if (!*s)
		return NULL;
	start = s;
	if (*s == '"') {
		s++;
		while (*s && *s != '"')
			s++;
		if (*s)
			s++;
	} else {
		while (*s && !isspace((unsigned char)*s))
			s++;
	}
	if (*s)
		*s++ = '\0';
	*p = s;
	return start;
}

static long number(const char *s, const char *what)
{
	char *end;
	long v = strtol(s, &end, 0);
	if (*s == '\0' || *end != '\0')
		fail("bad number for %s: %s", what, s);
	return v;
}

static void put(int *len, int byte)
{
	if (*len >= MAX_BLOCK)
		fail("block longer than %d bytes", MAX_BLOCK);
	block[(*len)++] = (unsigned char)byte;
}

/* send items: hex bytes, "text", u16=N, u32=N, pad=N, fill=N, file=PATH[:OFF[:LEN]] */
static int buildBlock(char *rest)
{
	char *tok;
	int len = 0;

	while ((tok = nextToken(&rest))) {
		if (tok[0] == '"') {
			size_t n = strlen(tok);
			if (n < 2 || tok[n - 1] != '"')
				fail("unterminated string %s", tok);
			for (size_t i = 1; i < n - 1; i++)
				put(&len, tok[i]);
		} else if (!strncmp(tok, "u16=", 4)) {
			long v = number(tok + 4, "u16");
			put(&len, v & 0xFF);
			put(&len, (v >> 8) & 0xFF);
		} else if (!strncmp(tok, "u32=", 4)) {
			long v = number(tok + 4, "u32");
			for (int i = 0; i < 4; i++)
				put(&len, (v >> (8 * i)) & 0xFF);
		} else if (!strncmp(tok, "pad=", 4)) {
			long n = number(tok + 4, "pad");
			while (len < n)
				put(&len, 0);
		} else if (!strncmp(tok, "fill=", 5)) {
			long n = number(tok + 5, "fill");
			for (long i = 0; i < n; i++)
				put(&len, i & 0xFF);
		} else if (!strncmp(tok, "file=", 5)) {
			char *path = tok + 5, *colon = strchr(path, ':');
			long off = 0, count = -1;
			if (colon) {
				*colon = '\0';
				char *colon2 = strchr(colon + 1, ':');
				if (colon2) {
					*colon2 = '\0';
					count = number(colon2 + 1, "file length");
				}
				off = number(colon + 1, "file offset");
			}
			FILE *f = fopen(path, "rb");
			if (!f)
				fail("cannot open %s: %s", path, strerror(errno));
			fseek(f, off, SEEK_SET);
			int c;
			while ((count < 0 || count-- > 0) && (c = fgetc(f)) != EOF)
				put(&len, c);
			fclose(f);
		} else if (isxdigit((unsigned char)tok[0]) && strlen(tok) == 2 &&
		           isxdigit((unsigned char)tok[1])) {
			put(&len, (int)strtol(tok, NULL, 16));
		} else {
			fail("unknown send item: %s", tok);
		}
	}
	return len;
}

static void runStep(char *line)
{
	char *rest = line, *cmd = nextToken(&rest);
	if (!cmd || cmd[0] == '#')
		return;

	if (!strcmp(cmd, "send")) {
		stepSend(buildBlock(rest));
	} else if (!strcmp(cmd, "recv")) {
		int maxLen = MAX_BLOCK, dumpMax = 96;
		const char *save = NULL;
		char *tok;
		while ((tok = nextToken(&rest))) {
			if (!strncmp(tok, "max=", 4))
				maxLen = number(tok + 4, "max");
			else if (!strcmp(tok, "all"))
				dumpMax = -1;
			else if (!strncmp(tok, "show=", 5))
				dumpMax = number(tok + 5, "show");
			else if (!strncmp(tok, "save=", 5))
				save = tok + 5;
			else
				fail("unknown recv option: %s", tok);
		}
		stepRecv(maxLen, dumpMax, save);
	} else if (!strcmp(cmd, "sync")) {
		stepSync();
	} else if (!strcmp(cmd, "peek")) {
		char *tok = nextToken(&rest);
		stepPeek(tok ? number(tok, "peek") : 4);
	} else if (!strcmp(cmd, "sleep")) {
		char *tok = nextToken(&rest);
		usleep(number(tok ? tok : "", "sleep") * 1000);
	} else if (!strcmp(cmd, "timeout")) {
		char *tok = nextToken(&rest);
		edgeTimeoutMs = number(tok ? tok : "", "timeout");
		printf("= timeout %ld ms\n", edgeTimeoutMs);
	} else if (!strcmp(cmd, "echo")) {
		printf("# %s\n", rest);
	} else {
		fail("unknown step: %s", cmd);
	}
}

static void releasePins(void)
{
	pinMode(pinBitOut, INPUT);
	pinMode(pinClkOut, INPUT);
}

static void onSignal(int sig)
{
	releasePins();
	signal(sig, SIG_DFL);
	raise(sig);
}

int main(int argc, char *argv[])
{
	char line[MAX_LINE];
	FILE *in;
	volatile int lineNo = 0;
	int argi = 1;

	if (argi < argc && !strcmp(argv[argi], "-t")) {
		verboseTiming = 1;
		argi++;
	}
	if (argi != argc - 1) {
		fprintf(stderr, "Usage: %s [-t] SCRIPT|-\n"
		        "  -t  print how long each step took (to stderr)\n", argv[0]);
		return 2;
	}
	in = strcmp(argv[argi], "-") ? fopen(argv[argi], "r") : stdin;
	if (!in) {
		perror(argv[argi]);
		return 2;
	}

	if (wiringPiSetup() == -1) {
		fprintf(stderr, "wiringPiSetup failed\n");
		return 2;
	}
	pinMode(pinClkIn, INPUT);
	pinMode(pinBitIn, INPUT);
	pinMode(pinClkOut, OUTPUT);
	pinMode(pinBitOut, OUTPUT);
	signal(SIGINT, onSignal);
	signal(SIGTERM, onSignal);

	while (fgets(line, sizeof line, in)) {
		line[strcspn(line, "\r\n")] = '\0';
		lineNo++;
		double t0 = nowMs();
		if (setjmp(stepFailed)) {
			printf("  ! line %d: %s\n", lineNo, failReason);
			errors++;
		} else {
			runStep(line);
		}
		if (verboseTiming)
			fprintf(stderr, "line %d: %.0f ms\n", lineNo, nowMs() - t0);
		fflush(stdout);
	}

	releasePins();
	printf("= %d error%s\n", errors, errors == 1 ? "" : "s");
	return errors ? 1 : 0;
}
