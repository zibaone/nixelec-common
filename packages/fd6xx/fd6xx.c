// SPDX-License-Identifier: MIT
//
// fd6xx — afficheur de facade 7 segments des boites H616/H618 (FD650/FD655).
//
// Ces dalles ne sont PAS sur un bus I2C du SoC : deux GPIO bit-banges
// (CLK/DAT), un protocole TWI maison. Et la puce **n'ACK pas** — mesure sur
// les deux cartes — donc `i2c-gpio` + un pilote I2C du noyau ne peuvent pas
// la piloter : i2c-gpio rend `-ENXIO` des le premier octet et le probe
// echoue. D'ou cet outil en espace utilisateur, qui parle le protocole
// directement par l'API gpio-v2.
//
// Protocole mesure (H96 Max H618, puce FD655) :
//   - START, octet de commande, 8 bits MSB d'abord, puis un **9e top
//     d'horloge** (la puce ne tire pas DAT : le 9e top est obligatoire quand
//     meme, sans lui des octets sont perdus — mesure), STOP ;
//   - commande 0x48 = controle, donnee = (niveau de luminosite + 1) << 4 | 0x01 ;
//   - adresses de donnees 0x68, 0x6A, 0x6C, 0x6E, 0x70 ; l'adresse 0x68 est
//     le chiffre **le plus a droite** (mesure sur la H96) ;
//   - l'octet d'icones est 0x66 (commande 0x33 * 2, registre « icon-set ») :
//     colon, USB, wifi, etc. selon la dalle ; il est hors des grilles de
//     chiffres et n'est pas ecrit par `write`/`blank`/`test` ;
//   - un octet de donnee = DP G F E D C B A (bit 7 = point, bit 0 = segment A).
//
// Les lignes sont demandees en sortie **open-drain avec pull-up interne au
// SoC** : l'etat haut n'est jamais pousse, ce qui est le cablage reel (DAT
// est open-drain des deux cotes). Sans le pull-up explicite, une ligne
// relachee flotte et les trames sont perdues.
//
// `show` est le rendu complet : texte + bits d'icones (wifi, eth, colonne,
// etc.). Les bits sont adresses par `ADDR:MASK`, ce qui permet de decrire un
// profil de dalle sans coder en dur une carte : l'adresse peut etre une
// grille de chiffre (le bit est alors OR/AND dans l'octet du chiffre) ou une
// adresse separee (une transaction dediee). La puce n'a pas de lecture de la
// RAM d'affichage : toute icone connue du profil doit donc etre passee, avec
// `--bit` si elle est active et `--clear` sinon, pour que l'etat soit complet.
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/gpio.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

#define MAX_GRIDS 5
#define MAX_BITOPS 32
#define MAX_EXTRAS 16
#define CMD_CTRL 0x48
#define DEFAULT_BASE 0x68
#define DEFAULT_STRIDE 2

struct bitop {
	unsigned addr;
	unsigned char mask;
	int set;
};

struct extra_write {
	unsigned addr;
	unsigned char byte;
};

struct frame {
	unsigned char grids[MAX_GRIDS];
	struct extra_write extras[MAX_EXTRAS];
	int n_extras;
	int digits;
	int overflow;
};

static int gfd, reqfd;
static long dly_ns = 5000; /* demi-periode : 5 us, ~100 kHz */

static void die(const char *what)
{
	fprintf(stderr, "fd6xx: %s: %s\n", what, strerror(errno));
	exit(1);
}

/* bits des valeurs = position dans la requete (0 = clk, 1 = dat) */
static void set2(int clk, int dat)
{
	struct gpio_v2_line_values lv;

	memset(&lv, 0, sizeof(lv));
	lv.mask = 0x3;
	lv.bits = (clk ? 0x1 : 0) | (dat ? 0x2 : 0);
	if (ioctl(reqfd, GPIO_V2_LINE_SET_VALUES_IOCTL, &lv) < 0)
		die("set_values");
}

static void nsleep(long ns)
{
	struct timespec ts;

	ts.tv_sec = ns / 1000000000L;
	ts.tv_nsec = ns % 1000000000L;
	nanosleep(&ts, NULL);
}

static void bb_start(void)
{
	set2(1, 1);
	nsleep(dly_ns);
	set2(1, 0);
	nsleep(dly_ns);
	set2(0, 0);
	nsleep(dly_ns);
}

static void bb_stop(void)
{
	set2(0, 0);
	nsleep(dly_ns);
	set2(1, 0);
	nsleep(dly_ns);
	set2(1, 1);
	nsleep(dly_ns);
}

/* octet MSB d'abord, plus le 9e top d'horloge que la puce attend */
static void bb_byte(unsigned b)
{
	int i;

	for (i = 7; i >= 0; i--) {
		int bit = (b >> i) & 1;
		set2(0, bit);
		nsleep(dly_ns);
		set2(1, bit);
		nsleep(dly_ns);
	}
	set2(0, 1);
	nsleep(dly_ns);
	set2(1, 1);
	nsleep(dly_ns);
	set2(0, 1);
	nsleep(dly_ns);
}

static void write_cmd_data(unsigned cmd, unsigned data)
{
	bb_start();
	bb_byte(cmd);
	bb_byte(data);
	bb_stop();
}

/*
 * Ecriture en bloc, mode « adresse incrementale » (vendor FD628) :
 *   START 0x40 STOP                      -> mode d'ecriture incrementale
 *   START (0xC0 | addr) octet... STOP    -> tete + N octets d'un seul tenant
 * C'est la sequence de `FD628_WrDisp_AddrINC` (`aml_fd628.c`), avec ses
 * constantes `FD628_ADDR_INC_DIGWR_CMD` (0x40) et `FD628_DIGADDR_WRCMD`
 * (0xC0). Sert a sonder une dalle dont on ne connait pas le mode.
 *
 * Mesure du 2026-11-26 : la Transpeed n'obéit pas mieux au bloc qu'a l'ecriture
 * par adresse — elle accepte des trames pendant ~2 min apres un cycle secteur,
 * puis n'en accepte plus aucune (dalle partiellement defaillante, cf.
 * nixelec-sunxi64/docs/affichage-facade.md). Conserve comme outil de sondage.
 */
static void write_burst(unsigned addr, const unsigned char *data, int n)
{
	int i;

	bb_start();
	bb_byte(0x40u);
	bb_stop();
	bb_start();
	bb_byte(0xc0u | (addr & 0x3fu));
	for (i = 0; i < n; i++)
		bb_byte(data[i]);
	bb_stop();
}

/* police 7 segments, DP G F E D C B A */
static unsigned char glyph(char c)
{
	switch (c) {
	case '0': return 0x3f;
	case '1': return 0x06;
	case '2': return 0x5b;
	case '3': return 0x4f;
	case '4': return 0x66;
	case '5': return 0x6d;
	case '6': return 0x7d;
	case '7': return 0x07;
	case '8': return 0x7f;
	case '9': return 0x6f;
	case 'A': case 'a': return 0x77;
	case 'b': case 'B': return 0x7c;
	case 'C': return 0x39;
	case 'c': return 0x58;
	case 'd': case 'D': return 0x5e;
	case 'E': case 'e': return 0x79;
	case 'F': case 'f': return 0x71;
	case 'G': case 'g': return 0x3d;
	case 'H': case 'h': return 0x76;
	case 'I': case 'i': return 0x06;
	case 'J': case 'j': return 0x1e;
	case 'L': case 'l': return 0x38;
	case 'N': return 0x37;
	case 'n': return 0x54;
	case 'o': case 'O': return 0x5c;
	case 'P': case 'p': return 0x73;
	case 'R': return 0x50;
	case 'r': return 0x50;
	case 'S': case 's': return 0x6d;
	case 'T': case 't': return 0x78;
	case 'U': case 'u': return 0x3e;
	case 'Y': case 'y': return 0x6e;
	case 'Z': case 'z': return 0x5b;
	case '-': return 0x40;
	case '_': return 0x08;
	case ' ': return 0x00;
	default: return 0x00;
	}
}

/*
 * Compose une trame complete sans toucher au GPIO. `base`/`stride` decrivent
 * l'adressage des grilles (0x68 + 2*i par defaut) ; un bit dont l'adresse
 * tombe sur une grille est applique dans l'octet du chiffre, sinon il devient
 * une ecriture separee. `--clear` est un AND, `--bit` un OR : l'ordre des
 * operations est celui de la ligne de commande.
 */
static void compose_frame(struct frame *f, const char *text, int ltr, int digits,
			  const struct bitop *ops, int nops, unsigned base,
			  unsigned stride)
{
	int i, n;

	memset(f, 0, sizeof(*f));
	if (digits < 1)
		digits = 1;
	if (digits > MAX_GRIDS)
		digits = MAX_GRIDS;
	f->digits = digits;

	n = (int)strlen(text);
	if (n > digits)
		n = digits;
	for (i = 0; i < n; i++)
		f->grids[i] = glyph(text[ltr ? i : n - 1 - i]);

	for (i = 0; i < nops; i++) {
		unsigned a = ops[i].addr;
		int idx = -1;
		int j;

		for (j = 0; j < MAX_GRIDS; j++) {
			if (a == base + stride * (unsigned)j) {
				idx = j;
				break;
			}
		}
		if (idx >= 0) {
			if (ops[i].set)
				f->grids[idx] |= ops[i].mask;
			else
				f->grids[idx] &= (unsigned char)~ops[i].mask;
			continue;
		}

		for (j = 0; j < f->n_extras; j++) {
			if (f->extras[j].addr == a)
				break;
		}
		if (j == f->n_extras) {
			if (f->n_extras >= MAX_EXTRAS) {
				f->overflow = 1;
				continue;
			}
			f->extras[j].addr = a;
			f->extras[j].byte = 0;
			f->n_extras++;
		}
		if (ops[i].set)
			f->extras[j].byte |= ops[i].mask;
		else
			f->extras[j].byte &= (unsigned char)~ops[i].mask;
	}
}

static void write_frame(const struct frame *f, unsigned base, unsigned stride)
{
	int i;

	for (i = 0; i < MAX_GRIDS; i++)
		write_cmd_data(base + stride * (unsigned)i, f->grids[i]);
	for (i = 0; i < f->n_extras; i++)
		write_cmd_data(f->extras[i].addr, f->extras[i].byte);
}

static int parse_byte(const char *s, unsigned *out)
{
	char *end;
	unsigned long v;

	errno = 0;
	v = strtoul(s, &end, 0);
	if (errno || end == s || *end != '\0' || v > 0xff)
		return -1;
	*out = (unsigned)v;
	return 0;
}

static int parse_bitop(const char *s, int set, struct bitop *op)
{
	char *end;
	unsigned long addr, mask;

	errno = 0;
	addr = strtoul(s, &end, 0);
	if (errno || end == s || *end != ':') {
		fprintf(stderr, "fd6xx: option %s attend ADDR:MASK (ex. 0x70:0x40)\n",
			set ? "--bit" : "--clear");
		return -1;
	}
	mask = strtoul(end + 1, &end, 0);
	if (errno || *end != '\0' || addr > 0xff || mask == 0 || mask > 0xff) {
		fprintf(stderr, "fd6xx: ADDR:MASK hors bornes dans %s\n", s);
		return -1;
	}
	op->addr = (unsigned)addr;
	op->mask = (unsigned char)mask;
	op->set = set;
	return 0;
}

static void init_gpio(const char *chip, int clk, int dat, int push_pull)
{
	struct gpio_v2_line_request req;
	unsigned long long flagsets[] = {
		GPIO_V2_LINE_FLAG_OUTPUT | GPIO_V2_LINE_FLAG_OPEN_DRAIN |
			GPIO_V2_LINE_FLAG_BIAS_PULL_UP,
		GPIO_V2_LINE_FLAG_OUTPUT | GPIO_V2_LINE_FLAG_OPEN_DRAIN,
		GPIO_V2_LINE_FLAG_OUTPUT,
	};
	int first = push_pull ? 2 : 0;
	int last = push_pull ? 3 : 2;
	int chosen = -1;
	int i;

	gfd = open(chip, O_RDWR | O_CLOEXEC);
	if (gfd < 0)
		die(chip);

	/* open-drain + pull-up : jamais de haut pousse, la ligne remonte.
	 * push-pull : le vendor Allwinner pilote en sortie franche (les cartes
	 * sans pull-up externe, comme la Transpeed, ne marchent que comme ca). */
	for (i = first; i < last; i++) {
		memset(&req, 0, sizeof(req));
		req.num_lines = 2;
		req.offsets[0] = clk;
		req.offsets[1] = dat;
		req.config.flags = flagsets[i];
		strncpy(req.consumer, "fd6xx", sizeof(req.consumer) - 1);
		if (ioctl(gfd, GPIO_V2_GET_LINE_IOCTL, &req) == 0) {
			chosen = i;
			break;
		}
	}
	if (chosen < 0)
		die("GPIO_V2_GET_LINE_IOCTL");
	reqfd = req.fd;
}

/*
 * Balaye un bit a la fois et affiche l'adresse testee : c'est la seule facon
 * de decouvrir une colonne ou une icone dont on ne connait pas le bit. Sans
 * --addr, balaye les cinq grilles ; avec --addr, balaye les huit bits de
 * cette adresse. La duree est volontairement lente : l'operateur regarde la
 * dalle, pas le terminal.
 */
static void scan_panel(unsigned base, unsigned stride, long scan_addr,
		       int scan_delay_ms)
{
	int i, bit;

	if (scan_addr >= 0) {
		for (bit = 0; bit < 8; bit++) {
			unsigned mask = 1u << bit;

			fprintf(stderr, "addr=0x%02lx mask=0x%02x\n",
				(unsigned long)scan_addr, mask);
			write_cmd_data((unsigned)scan_addr, mask);
			nsleep((long)scan_delay_ms * 1000000L);
			write_cmd_data((unsigned)scan_addr, 0);
			nsleep((long)scan_delay_ms * 1000000L / 2);
		}
		return;
	}

	for (i = 0; i < MAX_GRIDS; i++) {
		unsigned a = base + stride * (unsigned)i;

		for (bit = 0; bit < 8; bit++) {
			unsigned mask = 1u << bit;

			fprintf(stderr, "grid=%d addr=0x%02x mask=0x%02x\n",
				i, a, mask);
			write_cmd_data(a, mask);
			nsleep((long)scan_delay_ms * 1000000L);
			write_cmd_data(a, 0);
			nsleep((long)scan_delay_ms * 1000000L / 2);
		}
	}
}

static int selftest(void)
{
	struct frame f;
	struct bitop op;
	int fails = 0;

#define CHECK(cond) \
	do { \
		if (!(cond)) { \
			fprintf(stderr, "fd6xx: selftest FAIL ligne %d: %s\n", \
				__LINE__, #cond); \
			fails++; \
		} \
	} while (0)

	/* H96 : 0x68 est le chiffre de droite, le texte se remplit a l'envers. */
	compose_frame(&f, "H96", 0, 5, NULL, 0, DEFAULT_BASE, DEFAULT_STRIDE);
	CHECK(f.grids[0] == glyph('6'));
	CHECK(f.grids[1] == glyph('9'));
	CHECK(f.grids[2] == glyph('H'));
	CHECK(f.grids[3] == 0x00);
	CHECK(f.grids[4] == 0x00);
	CHECK(f.n_extras == 0);
	CHECK(!f.overflow);

	/* Transpeed : 0x68 est le chiffre de gauche. */
	compose_frame(&f, "H96", 1, 5, NULL, 0, DEFAULT_BASE, DEFAULT_STRIDE);
	CHECK(f.grids[0] == glyph('H'));
	CHECK(f.grids[1] == glyph('9'));
	CHECK(f.grids[2] == glyph('6'));

	/* Quatre positions : la cinquieme grille reste eteinte. */
	compose_frame(&f, "8618", 1, 4, NULL, 0, DEFAULT_BASE, DEFAULT_STRIDE);
	CHECK(f.grids[0] == glyph('8'));
	CHECK(f.grids[1] == glyph('6'));
	CHECK(f.grids[2] == glyph('1'));
	CHECK(f.grids[3] == glyph('8'));
	CHECK(f.grids[4] == 0x00);

	/* Les lettres du jeu de base, dont S qui partage le glyphe de 5. */
	compose_frame(&f, "TEST", 1, 4, NULL, 0, DEFAULT_BASE, DEFAULT_STRIDE);
	CHECK(f.grids[0] == glyph('T'));
	CHECK(f.grids[1] == glyph('E'));
	CHECK(f.grids[2] == glyph('S'));
	CHECK(f.grids[3] == glyph('T'));
	CHECK(glyph('S') == glyph('5'));

	/* Troncature au nombre de positions du profil : on garde les premiers
	 * caracteres, donc « 12345 » a l'ecran (0x68 = droite sur la H96). */
	compose_frame(&f, "123456", 0, 5, NULL, 0, DEFAULT_BASE, DEFAULT_STRIDE);
	CHECK(f.grids[0] == glyph('5'));
	CHECK(f.grids[1] == glyph('4'));
	CHECK(f.grids[2] == glyph('3'));
	CHECK(f.grids[3] == glyph('2'));
	CHECK(f.grids[4] == glyph('1'));

	/* Un bit sur une grille est OR/AND dans l'octet du chiffre. */
	op.addr = DEFAULT_BASE + DEFAULT_STRIDE * 2;
	op.mask = 0x80;
	op.set = 1;
	compose_frame(&f, "H96", 0, 5, &op, 1, DEFAULT_BASE, DEFAULT_STRIDE);
	CHECK(f.grids[2] == (unsigned char)(glyph('H') | 0x80));
	op.set = 0;
	compose_frame(&f, "H96", 0, 5, &op, 1, DEFAULT_BASE, DEFAULT_STRIDE);
	CHECK(f.grids[2] == glyph('H'));

	/* Une adresse hors grille devient une ecriture separee, fusionnee si
	 * plusieurs bits visent la meme adresse. */
	op.addr = 0x66;
	op.mask = 0x20;
	op.set = 1;
	compose_frame(&f, "H96", 0, 5, &op, 1, DEFAULT_BASE, DEFAULT_STRIDE);
	CHECK(f.n_extras == 1);
	CHECK(f.extras[0].addr == 0x66);
	CHECK(f.extras[0].byte == 0x20);
	op.set = 0;
	compose_frame(&f, "H96", 0, 5, &op, 1, DEFAULT_BASE, DEFAULT_STRIDE);
	CHECK(f.n_extras == 1);
	CHECK(f.extras[0].byte == 0x00);

	/* La cinquieme grille peut aussi porter une icone. */
	op.addr = DEFAULT_BASE + DEFAULT_STRIDE * 4;
	op.mask = 0x40;
	op.set = 1;
	compose_frame(&f, "8618", 1, 4, &op, 1, DEFAULT_BASE, DEFAULT_STRIDE);
	CHECK(f.grids[4] == 0x40);
	CHECK(f.n_extras == 0);

	/* Glyphe inconnu : eteint, jamais un segment au hasard. */
	compose_frame(&f, "K", 0, 5, NULL, 0, DEFAULT_BASE, DEFAULT_STRIDE);
	CHECK(f.grids[0] == 0x00);

	if (fails == 0)
		printf("fd6xx selftest: ok\n");
	return fails ? 1 : 0;
#undef CHECK
}

static void usage(void)
{
	fprintf(stderr,
		"usage: fd6xx [options] <commande>\n"
		"\n"
		"options:\n"
		"  --chip DEV        gpiochip (defaut /dev/gpiochip1)\n"
		"  --clk N           GPIO global de l'horloge (defaut 226)\n"
		"  --dat N           GPIO global des donnees (defaut 227)\n"
		"  --brightness 0-7  luminosite (defaut 3)\n"
		"  --base N          adresse de la premiere grille (defaut 0x68)\n"
		"  --stride N        pas entre deux grilles (defaut 2)\n"
		"  --digits 1-5      nombre de positions du profil (defaut 5)\n"
		"  --delay NS        demi-periode du bit-bang (defaut 5000)\n"
		"  --scan-delay MS   pause entre deux bits de `scan` (defaut 800)\n"
		"  --push-pull       sortie franche au lieu d'open-drain + pull-up\n"
		"                    (requis par les cartes sans pull-up, Transpeed)\n"
		"  --ltr             l'adresse de base est le chiffre de gauche\n"
		"  --dry-run         compose et affiche la trame sans ouvrir le GPIO\n"
		"\n"
		"commandes:\n"
		"  write <texte>     affiche jusqu'a --digits caracteres\n"
		"  show [--text TEXTE] [--bit ADDR:MASK]... [--clear ADDR:MASK]...\n"
		"                    rendu complet : texte + icones/colonne. Passer\n"
		"                    toutes les icones du profil, actives ou non.\n"
		"  seg <hex>...      octets de segments bruts, par adresse\n"
		"  raw <addr> <octet> [<addr> <octet>]...\n"
		"                    ecriture brute, pour sonder une adresse\n"
		"  burst <addr> <octet>...\n"
		"                    bloc en mode incremental du vendor : commande\n"
		"                    0x40 puis (0xC0|addr) et les octets d'un tenant.\n"
		"                    Pour les dalles qui ignorent l'ecriture par\n"
		"                    adresse (Transpeed).\n"
		"  scan [--addr ADDR]\n"
		"                    allume un bit a la fois et affiche l'adresse ;\n"
		"                    sans --addr, balaye les cinq grilles\n"
		"  blank             eteint les chiffres\n"
		"  test              allume tous les segments\n"
		"  selftest          verifie la composition des trames, sans GPIO\n"
		"\n"
		"defauts : --chip /dev/gpiochip1 --clk 226 --dat 227 (H96 : PH2/PH3)\n");
	exit(2);
}

int main(int argc, char **argv)
{
	const char *chip = "/dev/gpiochip1";
	int clk = 226, dat = 227, brightness = 3;
	int i, argi = 1, push_pull = 0, ltr = 0, dry_run = 0;
	int digits = MAX_GRIDS, scan_delay_ms = 800;
	unsigned base = DEFAULT_BASE, stride = DEFAULT_STRIDE;
	long scan_addr = -1;
	const char *cmd;

	while (argi < argc && !strncmp(argv[argi], "--", 2)) {
		const char *opt = argv[argi++];
		const char *val;

		if (!strcmp(opt, "--push-pull")) {
			push_pull = 1;
			continue;
		}
		if (!strcmp(opt, "--ltr")) {
			ltr = 1;
			continue;
		}
		if (!strcmp(opt, "--dry-run")) {
			dry_run = 1;
			continue;
		}
		val = (argi < argc) ? argv[argi++] : NULL;
		if (!val) {
			fprintf(stderr, "fd6xx: %s attend une valeur\n", opt);
			return 2;
		}
		if (!strcmp(opt, "--chip"))
			chip = val;
		else if (!strcmp(opt, "--clk"))
			clk = atoi(val);
		else if (!strcmp(opt, "--dat"))
			dat = atoi(val);
		else if (!strcmp(opt, "--brightness"))
			brightness = atoi(val) & 7;
		else if (!strcmp(opt, "--delay"))
			dly_ns = atol(val);
		else if (!strcmp(opt, "--scan-delay"))
			scan_delay_ms = atoi(val);
		else if (!strcmp(opt, "--digits"))
			digits = atoi(val);
		else if (!strcmp(opt, "--base")) {
			unsigned v;

			if (parse_byte(val, &v) < 0) {
				fprintf(stderr, "fd6xx: --base hors bornes\n");
				return 2;
			}
			base = v;
		} else if (!strcmp(opt, "--stride")) {
			stride = (unsigned)atoi(val);
		} else {
			fprintf(stderr, "fd6xx: option inconnue %s\n", opt);
			return 2;
		}
	}
	if (argi >= argc)
		usage();

	cmd = argv[argi++];

	if (!strcmp(cmd, "selftest"))
		return selftest();

	if (digits < 1 || digits > MAX_GRIDS) {
		fprintf(stderr, "fd6xx: --digits doit etre entre 1 et %d\n",
			MAX_GRIDS);
		return 2;
	}
	if (stride < 1 || stride > 8 ||
	    base + stride * (unsigned)(MAX_GRIDS - 1) > 0xff) {
		fprintf(stderr, "fd6xx: --base/--stride sortent de l'espace 8 bits\n");
		return 2;
	}

	if (!strcmp(cmd, "show")) {
		const char *text = "";
		struct bitop ops[MAX_BITOPS];
		struct frame f;
		int nops = 0;

		while (argi < argc) {
			const char *opt = argv[argi++];

			if (!strcmp(opt, "--text")) {
				if (argi >= argc)
					usage();
				text = argv[argi++];
			} else if (!strcmp(opt, "--bit") ||
				   !strcmp(opt, "--clear")) {
				if (argi >= argc)
					usage();
				if (nops >= MAX_BITOPS) {
					fprintf(stderr, "fd6xx: trop de --bit/--clear\n");
					return 2;
				}
				if (parse_bitop(argv[argi++], !strcmp(opt, "--bit"),
						&ops[nops]) < 0)
					return 2;
				nops++;
			} else {
				usage();
			}
		}

		compose_frame(&f, text, ltr, digits, ops, nops, base, stride);
		if (f.overflow) {
			fprintf(stderr, "fd6xx: trop d'adresses d'icones distinctes\n");
			return 2;
		}
		if (dry_run) {
			for (i = 0; i < MAX_GRIDS; i++)
				printf("grid[%d] addr=0x%02x byte=0x%02x\n", i,
				       base + stride * (unsigned)i, f.grids[i]);
			for (i = 0; i < f.n_extras; i++)
				printf("extra addr=0x%02x byte=0x%02x\n",
				       f.extras[i].addr, f.extras[i].byte);
			return 0;
		}
		init_gpio(chip, clk, dat, push_pull);
		write_cmd_data(CMD_CTRL,
			       (((brightness + 1) << 4) | 0x01));
		write_frame(&f, base, stride);
		return 0;
	}

	if (!strcmp(cmd, "raw")) {
		struct extra_write pairs[MAX_EXTRAS];
		int npairs = 0;

		if (argi >= argc || (argc - argi) % 2 != 0)
			usage();
		while (argi < argc) {
			unsigned a, v;

			if (npairs >= MAX_EXTRAS) {
				fprintf(stderr, "fd6xx: trop de paires raw\n");
				return 2;
			}
			if (parse_byte(argv[argi++], &a) < 0 ||
			    parse_byte(argv[argi++], &v) < 0) {
				fprintf(stderr, "fd6xx: raw attend ADDR OCTET (0-255)\n");
				return 2;
			}
			pairs[npairs].addr = a;
			pairs[npairs].byte = (unsigned char)v;
			npairs++;
		}
		init_gpio(chip, clk, dat, push_pull);
		write_cmd_data(CMD_CTRL,
			       (((brightness + 1) << 4) | 0x01));
		for (i = 0; i < npairs; i++)
			write_cmd_data(pairs[i].addr, pairs[i].byte);
		return 0;
	}

	if (!strcmp(cmd, "burst")) {
		unsigned addr;
		unsigned char data[MAX_GRIDS + 1];
		int n = 0;

		if (argi >= argc || parse_byte(argv[argi++], &addr) < 0) {
			fprintf(stderr, "fd6xx: burst attend ADDR OCTET...\n");
			return 2;
		}
		while (argi < argc) {
			unsigned v;

			if (n >= (int)(MAX_GRIDS + 1)) {
				fprintf(stderr, "fd6xx: burst limite a %d octets\n",
					MAX_GRIDS + 1);
				return 2;
			}
			if (parse_byte(argv[argi++], &v) < 0) {
				fprintf(stderr, "fd6xx: burst attend des octets (0-255)\n");
				return 2;
			}
			data[n++] = (unsigned char)v;
		}
		if (n == 0)
			usage();
		init_gpio(chip, clk, dat, push_pull);
		write_cmd_data(CMD_CTRL, (((brightness + 1) << 4) | 0x01));
		write_burst(addr, data, n);
		return 0;
	}

	if (!strcmp(cmd, "scan")) {
		while (argi < argc) {
			const char *opt = argv[argi++];
			unsigned a;

			if (strcmp(opt, "--addr") || argi >= argc)
				usage();
			if (parse_byte(argv[argi++], &a) < 0) {
				fprintf(stderr, "fd6xx: --addr hors bornes\n");
				return 2;
			}
			scan_addr = (long)a;
		}
		init_gpio(chip, clk, dat, push_pull);
		write_cmd_data(CMD_CTRL,
			       (((brightness + 1) << 4) | 0x01));
		scan_panel(base, stride, scan_addr, scan_delay_ms);
		/* Le balayage laisse la dalle eteinte : on rend l'etat vide
		 * explicitement, pour ne pas laisser un segment residuel. */
		for (i = 0; i < MAX_GRIDS; i++)
			write_cmd_data(base + stride * (unsigned)i, 0);
		return 0;
	}

	init_gpio(chip, clk, dat, push_pull);
	write_cmd_data(CMD_CTRL, (((brightness + 1) << 4) | 0x01));

	if (!strcmp(cmd, "write")) {
		const char *text = (argi < argc) ? argv[argi] : "";
		struct frame f;

		compose_frame(&f, text, ltr, digits, NULL, 0, base, stride);
		write_frame(&f, base, stride);
	} else if (!strcmp(cmd, "seg")) {
		for (i = 0; i < MAX_GRIDS; i++) {
			unsigned v = (argi + i < argc) ?
					     (unsigned)strtoul(argv[argi + i], NULL, 0) :
					     0;
			write_cmd_data(base + stride * (unsigned)i, v & 0xff);
		}
	} else if (!strcmp(cmd, "blank")) {
		struct frame f;

		compose_frame(&f, "", ltr, digits, NULL, 0, base, stride);
		write_frame(&f, base, stride);
	} else if (!strcmp(cmd, "test")) {
		struct frame f;

		memset(&f, 0, sizeof(f));
		for (i = 0; i < MAX_GRIDS; i++)
			f.grids[i] = 0xff;
		write_frame(&f, base, stride);
	} else {
		usage();
	}

	return 0;
}
