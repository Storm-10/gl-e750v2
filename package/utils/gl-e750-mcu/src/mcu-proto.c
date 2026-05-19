#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/time.h>
#include <sys/select.h>
#include <termios.h>
#include <unistd.h>

struct strbuf {
    char *data;
    size_t len;
    size_t cap;
};

struct pair {
    char *key;
    char *value;
};

static void die(const char *msg)
{
    fprintf(stderr, "%s\n", msg);
    exit(1);
}

static void die_errno(const char *msg)
{
    fprintf(stderr, "%s: %s\n", msg, strerror(errno));
    exit(1);
}

static void sb_reserve(struct strbuf *sb, size_t need)
{
    if (need <= sb->cap)
        return;

    size_t cap = sb->cap ? sb->cap : 128;
    while (cap < need)
        cap *= 2;

    char *p = realloc(sb->data, cap);
    if (!p)
        die("out of memory");

    sb->data = p;
    sb->cap = cap;
}

static void sb_append_mem(struct strbuf *sb, const void *buf, size_t n)
{
    sb_reserve(sb, sb->len + n + 1);
    memcpy(sb->data + sb->len, buf, n);
    sb->len += n;
    sb->data[sb->len] = '\0';
}

static void sb_append_char(struct strbuf *sb, char c)
{
    sb_append_mem(sb, &c, 1);
}

static void sb_append_str(struct strbuf *sb, const char *s)
{
    sb_append_mem(sb, s, strlen(s));
}

static void skip_ws(const char **sp)
{
    while (**sp && isspace((unsigned char)**sp))
        (*sp)++;
}

static int hex_val(char c)
{
    if (c >= '0' && c <= '9')
        return c - '0';
    if (c >= 'a' && c <= 'f')
        return 10 + c - 'a';
    if (c >= 'A' && c <= 'F')
        return 10 + c - 'A';
    return -1;
}

static char *parse_json_string(const char **sp)
{
    const char *s = *sp;
    struct strbuf out = {0};

    if (*s != '"')
        return NULL;

    s++;
    while (*s) {
        unsigned char c = (unsigned char)*s++;

        if (c == '"') {
            *sp = s;
            return out.data ? out.data : strdup("");
        }

        if (c != '\\') {
            sb_append_char(&out, (char)c);
            continue;
        }

        c = (unsigned char)*s++;
        switch (c) {
        case '"':
        case '\\':
        case '/':
            sb_append_char(&out, (char)c);
            break;
        case 'b':
            sb_append_char(&out, '\b');
            break;
        case 'f':
            sb_append_char(&out, '\f');
            break;
        case 'n':
            sb_append_char(&out, '\n');
            break;
        case 'r':
            sb_append_char(&out, '\r');
            break;
        case 't':
            sb_append_char(&out, '\t');
            break;
        case 'u': {
            int v = 0;
            for (int i = 0; i < 4; i++) {
                int h = hex_val(*s++);
                if (h < 0)
                    die("invalid \\u escape");
                v = (v << 4) | h;
            }
            if (v <= 0xff) {
                sb_append_char(&out, (char)v);
            } else if (v <= 0x7ff) {
                sb_append_char(&out, (char)(0xc0 | (v >> 6)));
                sb_append_char(&out, (char)(0x80 | (v & 0x3f)));
            } else {
                sb_append_char(&out, (char)(0xe0 | (v >> 12)));
                sb_append_char(&out, (char)(0x80 | ((v >> 6) & 0x3f)));
                sb_append_char(&out, (char)(0x80 | (v & 0x3f)));
            }
            break;
        }
        default:
            die("unsupported JSON escape");
        }
    }

    die("unterminated JSON string");
    return NULL;
}

static struct pair *parse_flat_json_object(const char *json, size_t *count_out)
{
    const char *s = json;
    struct pair *pairs = NULL;
    size_t count = 0, cap = 0;

    skip_ws(&s);
    if (*s != '{')
        die("format-json expects a JSON object");
    s++;

    skip_ws(&s);
    if (*s == '}') {
        *count_out = 0;
        return NULL;
    }

    while (*s) {
        char *key, *value;
        skip_ws(&s);
        key = parse_json_string(&s);
        if (!key)
            die("expected string key");

        skip_ws(&s);
        if (*s != ':')
            die("expected ':' after key");
        s++;

        skip_ws(&s);
        value = parse_json_string(&s);
        if (!value)
            die("format-json only supports string values");

        if (count == cap) {
            cap = cap ? cap * 2 : 8;
            pairs = realloc(pairs, cap * sizeof(*pairs));
            if (!pairs)
                die("out of memory");
        }
        pairs[count].key = key;
        pairs[count].value = value;
        count++;

        skip_ws(&s);
        if (*s == '}') {
            s++;
            break;
        }
        if (*s != ',')
            die("expected ',' or '}'");
        s++;
    }

    skip_ws(&s);
    if (*s != '\0')
        die("unexpected trailing JSON data");

    *count_out = count;
    return pairs;
}

static char *vendor_preprocess_value(const char *value)
{
    struct strbuf out = {0};

    for (const unsigned char *p = (const unsigned char *)value; *p; p++) {
        switch (*p) {
        case '"':
            sb_append_char(&out, 0x04);
            break;
        case ':':
            sb_append_char(&out, 0x03);
            break;
        case '\\':
            sb_append_char(&out, 0x02);
            break;
        case '/':
            sb_append_char(&out, 0x01);
            break;
        default:
            sb_append_char(&out, (char)*p);
            break;
        }
    }

    return out.data ? out.data : strdup("");
}

static void json_escape_vendor_bytes(struct strbuf *sb, const char *s)
{
    for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
        switch (*p) {
        case '"':
            sb_append_str(sb, "\\\"");
            break;
        case '\\':
            sb_append_str(sb, "\\\\");
            break;
        case '\b':
            sb_append_str(sb, "\\b");
            break;
        case '\f':
            sb_append_str(sb, "\\f");
            break;
        case '\n':
            sb_append_str(sb, "\\n");
            break;
        case '\r':
            sb_append_str(sb, "\\r");
            break;
        case '\t':
            sb_append_str(sb, "\\t");
            break;
        case 0x01:
        case 0x02:
        case 0x03:
        case 0x04: {
            char tmp[7];
            snprintf(tmp, sizeof(tmp), "\\u%04x", *p);
            sb_append_str(sb, tmp);
            break;
        }
        default:
            if (*p < 0x20) {
                char tmp[7];
                snprintf(tmp, sizeof(tmp), "\\u%04x", *p);
                sb_append_str(sb, tmp);
            } else {
                sb_append_char(sb, (char)*p);
            }
            break;
        }
    }
}

static char *build_compact_json(struct pair *pairs, size_t count)
{
    struct strbuf out = {0};

    sb_append_char(&out, '{');
    for (size_t i = 0; i < count; i++) {
        char *pre = vendor_preprocess_value(pairs[i].value);
        if (i)
            sb_append_char(&out, ',');

        sb_append_char(&out, '"');
        json_escape_vendor_bytes(&out, pairs[i].key);
        sb_append_str(&out, "\":\"");
        json_escape_vendor_bytes(&out, pre);
        sb_append_char(&out, '"');
        free(pre);
    }
    sb_append_char(&out, '}');

    return out.data;
}

static char *vendor_format_json(const char *json)
{
    size_t count = 0;
    struct pair *pairs = parse_flat_json_object(json, &count);
    char *compact = build_compact_json(pairs, count);
    struct strbuf stage2 = {0};
    struct strbuf out = {0};
    size_t len = strlen(compact);

    if (len == 0)
        die("empty JSON");

    sb_append_char(&stage2, compact[0]);
    for (size_t i = 1; i + 1 < len; i++) {
        char c = compact[i];
        if (c == '{' || c == '}') {
            sb_append_char(&stage2, (char)(c - 100));
        } else if (c == '"' && compact[i - 1] == '\\' && compact[i + 1] != ' ') {
            sb_append_char(&stage2, (char)(c - 30));
        } else if (c == ':') {
            sb_append_str(&stage2, ": ");
        } else {
            sb_append_char(&stage2, c);
        }
    }
    sb_append_char(&stage2, '}');

    for (size_t i = 0; i < stage2.len; ) {
        if (i + 6 <= stage2.len && memcmp(stage2.data + i, "\\u0001", 6) == 0) {
            sb_append_char(&out, 0x01);
            i += 6;
        } else if (i + 6 <= stage2.len && memcmp(stage2.data + i, "\\u0002", 6) == 0) {
            sb_append_char(&out, 0x02);
            i += 6;
        } else if (i + 6 <= stage2.len && memcmp(stage2.data + i, "\\u0003", 6) == 0) {
            sb_append_char(&out, 0x03);
            i += 6;
        } else if (i + 6 <= stage2.len && memcmp(stage2.data + i, "\\u0004", 6) == 0) {
            sb_append_char(&out, 0x04);
            i += 6;
        } else {
            sb_append_char(&out, stage2.data[i++]);
        }
    }

    for (size_t i = 0; i < count; i++) {
        free(pairs[i].key);
        free(pairs[i].value);
    }
    free(pairs);
    free(compact);
    free(stage2.data);

    return out.data;
}

static char *vendor_raw_json(const char *json)
{
    struct strbuf out = {0};

    for (const char *p = json; *p; p++) {
        sb_append_char(&out, *p);
        if (*p == ':')
            sb_append_char(&out, ' ');
    }

    return out.data;
}

static void print_hex(const char *buf, size_t len)
{
    for (size_t i = 0; i < len; i++) {
        printf("%02x", (unsigned char)buf[i]);
        if (i + 1 < len)
            putchar(' ');
    }
    putchar('\n');
}

static void print_ascii_escaped(const char *buf, size_t len)
{
    for (size_t i = 0; i < len; i++) {
        unsigned char c = (unsigned char)buf[i];
        if (c == '\n') {
            fputs("\\n", stdout);
        } else if (c == '\r') {
            fputs("\\r", stdout);
        } else if (c == '\t') {
            fputs("\\t", stdout);
        } else if (isprint(c)) {
            putchar((char)c);
        } else {
            printf("\\x%02x", c);
        }
    }
    putchar('\n');
}

static long long now_ms(void)
{
    struct timeval tv;
    if (gettimeofday(&tv, NULL) < 0)
        die_errno("gettimeofday");
    return (long long)tv.tv_sec * 1000LL + (long long)tv.tv_usec / 1000LL;
}

static speed_t parse_baud(int baud)
{
    switch (baud) {
    case 9600: return B9600;
    case 19200: return B19200;
    case 38400: return B38400;
    case 57600: return B57600;
    case 115200: return B115200;
    default:
        die("unsupported baud rate");
    }

    return B115200;
}

static const char *speed_name(speed_t s)
{
    switch (s) {
    case B9600: return "9600";
    case B19200: return "19200";
    case B38400: return "38400";
    case B57600: return "57600";
    case B115200: return "115200";
    default: return "unknown";
    }
}

static void dump_termios(const char *label, const struct termios *t)
{
    printf("%s\n", label);
    printf("  iflag=0x%08lx\n", (unsigned long)t->c_iflag);
    printf("  oflag=0x%08lx\n", (unsigned long)t->c_oflag);
    printf("  cflag=0x%08lx\n", (unsigned long)t->c_cflag);
    printf("  lflag=0x%08lx\n", (unsigned long)t->c_lflag);
    printf("  ispeed=%s\n", speed_name(cfgetispeed((struct termios *)t)));
    printf("  ospeed=%s\n", speed_name(cfgetospeed((struct termios *)t)));
    printf("  VMIN=%u\n", (unsigned int)t->c_cc[VMIN]);
    printf("  VTIME=%u\n", (unsigned int)t->c_cc[VTIME]);
}

static int open_serial(const char *dev, int baud)
{
    int fd = open(dev, O_RDWR | O_NOCTTY);
    if (fd < 0)
        die_errno("open tty");

    struct termios tio;
    if (tcgetattr(fd, &tio) < 0)
        die_errno("tcgetattr");

    /* Match the vendor daemon: do not switch to full raw mode.
     * It only clears local canonical/echo/signal processing. */
    tio.c_lflag &= ~(ECHO | ICANON | ECHOE | ISIG);
    tio.c_cflag |= CLOCAL | CREAD;
    tio.c_cflag &= ~CSTOPB;
    tio.c_cflag &= ~PARENB;
    tio.c_cflag &= ~CRTSCTS;
    tio.c_cflag &= ~CSIZE;
    tio.c_cflag |= CS8;
    tio.c_cc[VMIN] = 0;
    tio.c_cc[VTIME] = 5;
    cfsetispeed(&tio, parse_baud(baud));
    cfsetospeed(&tio, parse_baud(baud));

    if (tcsetattr(fd, TCSANOW, &tio) < 0)
        die_errno("tcsetattr");

    return fd;
}

static void inspect_termios(const char *dev, int baud)
{
    int fd = open(dev, O_RDWR | O_NOCTTY);
    if (fd < 0)
        die_errno("open tty");

    struct termios before, after;
    if (tcgetattr(fd, &before) < 0)
        die_errno("tcgetattr(before)");
    dump_termios("before", &before);

    after = before;
    after.c_lflag &= ~(ECHO | ICANON | ECHOE | ISIG);
    after.c_cflag |= CLOCAL | CREAD;
    after.c_cflag &= ~CSTOPB;
    after.c_cflag &= ~PARENB;
    after.c_cflag &= ~CRTSCTS;
    after.c_cflag &= ~CSIZE;
    after.c_cflag |= CS8;
    after.c_cc[VMIN] = 0;
    after.c_cc[VTIME] = 5;
    cfsetispeed(&after, parse_baud(baud));
    cfsetospeed(&after, parse_baud(baud));

    if (tcsetattr(fd, TCSANOW, &after) < 0)
        die_errno("tcsetattr(after)");
    if (tcgetattr(fd, &after) < 0)
        die_errno("tcgetattr(after)");
    dump_termios("after", &after);

    close(fd);
}

static void write_all(int fd, const char *buf, size_t len)
{
    while (len) {
        ssize_t n = write(fd, buf, len);
        if (n < 0) {
            if (errno == EINTR)
                continue;
            die_errno("write");
        }
        buf += n;
        len -= (size_t)n;
    }
}

static char *read_reply(int fd, int first_timeout_ms, int next_timeout_ms, size_t *len_out)
{
    struct strbuf out = {0};
    int timeout_ms = first_timeout_ms;

    while (1) {
        fd_set rfds;
        struct timeval tv;
        FD_ZERO(&rfds);
        FD_SET(fd, &rfds);
        tv.tv_sec = timeout_ms / 1000;
        tv.tv_usec = (timeout_ms % 1000) * 1000;

        int rc = select(fd + 1, &rfds, NULL, NULL, &tv);
        if (rc < 0) {
            if (errno == EINTR)
                continue;
            die_errno("select");
        }
        if (rc == 0)
            break;

        char buf[256];
        ssize_t n = read(fd, buf, sizeof(buf));
        if (n < 0) {
            if (errno == EINTR)
                continue;
            die_errno("read");
        }
        if (n == 0)
            break;

        sb_append_mem(&out, buf, (size_t)n);
        timeout_ms = next_timeout_ms;
    }

    if (!out.data)
        out.data = strdup("");
    if (!out.data)
        die("out of memory");

    *len_out = out.len;
    return out.data;
}

static int read_one_chunk(int fd, int timeout_ms, char *buf, size_t buf_size, size_t *len_out)
{
    fd_set rfds;
    struct timeval tv;
    FD_ZERO(&rfds);
    FD_SET(fd, &rfds);
    tv.tv_sec = timeout_ms / 1000;
    tv.tv_usec = (timeout_ms % 1000) * 1000;

    int rc = select(fd + 1, &rfds, NULL, NULL, &tv);
    if (rc < 0) {
        if (errno == EINTR)
            return read_one_chunk(fd, timeout_ms, buf, buf_size, len_out);
        die_errno("select");
    }
    if (rc == 0) {
        *len_out = 0;
        return 0;
    }

    ssize_t n = read(fd, buf, buf_size);
    if (n < 0) {
        if (errno == EINTR)
            return read_one_chunk(fd, timeout_ms, buf, buf_size, len_out);
        die_errno("read");
    }

    *len_out = (size_t)n;
    return 1;
}

static void drain_input(int fd, int timeout_ms)
{
    size_t ignored_len = 0;
    char *ignored = read_reply(fd, timeout_ms, 100, &ignored_len);
    if (ignored_len > 0) {
        fprintf(stderr, "drained stale bytes: ");
        for (size_t i = 0; i < ignored_len; i++)
            fprintf(stderr, "%02x%s", (unsigned char)ignored[i], (i + 1 < ignored_len) ? " " : "");
        fputc('\n', stderr);
    }
    free(ignored);
}

static void flush_input(int fd)
{
    if (tcflush(fd, TCIFLUSH) < 0)
        die_errno("tcflush");
}

static char *build_frame(const char *mode, const char *payload)
{
    if (strcmp(mode, "raw-string") == 0)
        return strdup(payload);
    if (strcmp(mode, "raw-json") == 0)
        return vendor_raw_json(payload);
    if (strcmp(mode, "format-json") == 0)
        return vendor_format_json(payload);

    die("mode must be raw-string, raw-json, or format-json");
    return NULL;
}

static void trace_stream(int fd, int first_timeout_ms, int next_timeout_ms)
{
    char buf[256];
    size_t len = 0;
    int chunk = 0;
    int timeout_ms = first_timeout_ms;
    long long prev_ms = now_ms();

    while (1) {
        int rc = read_one_chunk(fd, timeout_ms, buf, sizeof(buf), &len);
        long long cur_ms = now_ms();
        long long delta = cur_ms - prev_ms;

        if (rc == 0 || len == 0)
            break;

        chunk++;
        printf("chunk=%d dt_ms=%lld len=%zu\n", chunk, delta, len);
        printf("hex: ");
        print_hex(buf, len);
        printf("ascii: ");
        print_ascii_escaped(buf, len);
        fflush(stdout);

        prev_ms = cur_ms;
        timeout_ms = next_timeout_ms;
    }
}

static void wait_for_idle(int fd, int idle_ms)
{
    long long last_rx = now_ms();
    char buf[256];
    size_t len = 0;

    while (1) {
        int rc = read_one_chunk(fd, idle_ms, buf, sizeof(buf), &len);
        long long cur = now_ms();

        if (rc == 0 || len == 0) {
            if (cur - last_rx >= idle_ms)
                return;
            continue;
        }

        last_rx = cur;
        printf("idle-drain len=%zu\n", len);
        printf("idle-drain hex: ");
        print_hex(buf, len);
        printf("idle-drain ascii: ");
        print_ascii_escaped(buf, len);
        fflush(stdout);
    }
}

static void chomp(char *s)
{
    size_t len = strlen(s);
    while (len > 0 && (s[len - 1] == '\n' || s[len - 1] == '\r')) {
        s[len - 1] = '\0';
        len--;
    }
}

static void interactive_session(int fd, int timeout_ms, int next_timeout_ms)
{
    char line[1024];

    fprintf(stderr,
        "session commands:\n"
        "  raw-string <payload>\n"
        "  raw-json <payload>\n"
        "  format-json <payload>\n"
        "  drain [timeout_ms]\n"
        "  flush\n"
        "  trace [timeout_ms] [next_timeout_ms]\n"
        "  quit\n");

    while (fgets(line, sizeof(line), stdin)) {
        chomp(line);

        if (strcmp(line, "quit") == 0 || strcmp(line, "exit") == 0)
            break;

        if (strncmp(line, "flush", 5) == 0) {
            flush_input(fd);
            printf("flushed input\n");
            fflush(stdout);
            continue;
        }

        if (strncmp(line, "drain", 5) == 0) {
            int t = timeout_ms;
            if (strlen(line) > 6)
                t = atoi(line + 6);
            drain_input(fd, t);
            continue;
        }

        if (strncmp(line, "trace", 5) == 0) {
            int t1 = timeout_ms;
            int t2 = next_timeout_ms;
            if (strlen(line) > 6) {
                char *p = line + 6;
                t1 = atoi(p);
                while (*p && !isspace((unsigned char)*p))
                    p++;
                while (*p && isspace((unsigned char)*p))
                    p++;
                if (*p)
                    t2 = atoi(p);
            }
            trace_stream(fd, t1, t2);
            continue;
        }

        char *sp = strchr(line, ' ');
        if (!sp) {
            fprintf(stderr, "bad command\n");
            continue;
        }

        *sp++ = '\0';
        while (*sp && isspace((unsigned char)*sp))
            sp++;

        char *frame = build_frame(line, sp);
        printf("tx len=%zu\n", strlen(frame));
        printf("tx hex: ");
        print_hex(frame, strlen(frame));
        printf("tx ascii: ");
        print_ascii_escaped(frame, strlen(frame));
        fflush(stdout);

        write_all(fd, frame, strlen(frame));
        free(frame);
        trace_stream(fd, timeout_ms, next_timeout_ms);
    }
}

static void usage(const char *prog)
{
    fprintf(stderr,
        "Usage:\n"
        "  %s termios <tty> <baud>\n"
        "  %s frame <raw-string|raw-json|format-json> <payload>\n"
        "  %s hex   <raw-string|raw-json|format-json> <payload>\n"
        "  %s drain <tty> <baud> [timeout_ms]\n"
        "  %s listen <tty> <baud> [timeout_ms]\n"
        "  %s trace <tty> <baud> [timeout_ms] [next_timeout_ms]\n"
        "  %s xact  <tty> <baud> <raw-string|raw-json|format-json> <payload> [timeout_ms] [next_timeout_ms]\n"
        "  %s idle-xact <tty> <baud> <idle_ms> <raw-string|raw-json|format-json> <payload> [timeout_ms] [next_timeout_ms]\n"
        "  %s session <tty> <baud> [timeout_ms] [next_timeout_ms]\n"
        "  %s send  <tty> <baud> <raw-string|raw-json|format-json> <payload> [timeout_ms]\n",
        prog, prog, prog, prog, prog, prog, prog, prog, prog, prog);
}

int main(int argc, char **argv)
{
    char *frame;

    if (argc < 4) {
        usage(argv[0]);
        return 1;
    }

    if (strcmp(argv[1], "frame") == 0) {
        frame = build_frame(argv[2], argv[3]);
        fwrite(frame, 1, strlen(frame), stdout);
        free(frame);
        return 0;
    }

    if (strcmp(argv[1], "termios") == 0) {
        if (argc < 4) {
            usage(argv[0]);
            return 1;
        }
        inspect_termios(argv[2], atoi(argv[3]));
        return 0;
    }

    if (strcmp(argv[1], "hex") == 0) {
        frame = build_frame(argv[2], argv[3]);
        print_hex(frame, strlen(frame));
        free(frame);
        return 0;
    }

    if (strcmp(argv[1], "send") == 0) {
        if (argc < 6) {
            usage(argv[0]);
            return 1;
        }

        int baud = atoi(argv[3]);
        int timeout_ms = argc > 6 ? atoi(argv[6]) : 3000;
        size_t reply_len = 0;
        int fd = open_serial(argv[2], baud);
        frame = build_frame(argv[4], argv[5]);

        drain_input(fd, 200);
        flush_input(fd);
        write_all(fd, frame, strlen(frame));
        free(frame);

        char *reply = read_reply(fd, timeout_ms, 1500, &reply_len);
        if (reply_len > 0)
            fwrite(reply, 1, reply_len, stdout);

        free(reply);
        close(fd);
        return 0;
    }

    if (strcmp(argv[1], "drain") == 0) {
        if (argc < 4) {
            usage(argv[0]);
            return 1;
        }

        int baud = atoi(argv[3]);
        int timeout_ms = argc > 4 ? atoi(argv[4]) : 3000;
        size_t reply_len = 0;
        int fd = open_serial(argv[2], baud);
        char *reply = read_reply(fd, timeout_ms, 300, &reply_len);
        if (reply_len > 0)
            fwrite(reply, 1, reply_len, stdout);
        free(reply);
        close(fd);
        return 0;
    }

    if (strcmp(argv[1], "listen") == 0) {
        if (argc < 4) {
            usage(argv[0]);
            return 1;
        }

        int baud = atoi(argv[3]);
        int timeout_ms = argc > 4 ? atoi(argv[4]) : 5000;
        int fd = open_serial(argv[2], baud);
        flush_input(fd);

        while (1) {
            size_t reply_len = 0;
            char *reply = read_reply(fd, timeout_ms, 1500, &reply_len);
            if (reply_len == 0) {
                free(reply);
                break;
            }
            fwrite(reply, 1, reply_len, stdout);
            fflush(stdout);
            free(reply);
        }

        close(fd);
        return 0;
    }

    if (strcmp(argv[1], "trace") == 0) {
        if (argc < 4) {
            usage(argv[0]);
            return 1;
        }

        int baud = atoi(argv[3]);
        int timeout_ms = argc > 4 ? atoi(argv[4]) : 5000;
        int next_timeout_ms = argc > 5 ? atoi(argv[5]) : 1500;
        int fd = open_serial(argv[2], baud);
        trace_stream(fd, timeout_ms, next_timeout_ms);
        close(fd);
        return 0;
    }

    if (strcmp(argv[1], "xact") == 0) {
        if (argc < 6) {
            usage(argv[0]);
            return 1;
        }

        int baud = atoi(argv[3]);
        int timeout_ms = argc > 6 ? atoi(argv[6]) : 5000;
        int next_timeout_ms = argc > 7 ? atoi(argv[7]) : 1500;
        int fd = open_serial(argv[2], baud);
        frame = build_frame(argv[4], argv[5]);

        drain_input(fd, 200);
        flush_input(fd);
        printf("tx len=%zu\n", strlen(frame));
        printf("tx hex: ");
        print_hex(frame, strlen(frame));
        printf("tx ascii: ");
        print_ascii_escaped(frame, strlen(frame));
        fflush(stdout);

        write_all(fd, frame, strlen(frame));
        free(frame);

        trace_stream(fd, timeout_ms, next_timeout_ms);
        close(fd);
        return 0;
    }

    if (strcmp(argv[1], "idle-xact") == 0) {
        if (argc < 7) {
            usage(argv[0]);
            return 1;
        }

        int baud = atoi(argv[3]);
        int idle_ms = atoi(argv[4]);
        int timeout_ms = argc > 7 ? atoi(argv[7]) : 5000;
        int next_timeout_ms = argc > 8 ? atoi(argv[8]) : 1500;
        int fd = open_serial(argv[2], baud);
        frame = build_frame(argv[5], argv[6]);

        drain_input(fd, 200);
        flush_input(fd);
        wait_for_idle(fd, idle_ms);
        printf("tx len=%zu\n", strlen(frame));
        printf("tx hex: ");
        print_hex(frame, strlen(frame));
        printf("tx ascii: ");
        print_ascii_escaped(frame, strlen(frame));
        fflush(stdout);

        write_all(fd, frame, strlen(frame));
        free(frame);

        trace_stream(fd, timeout_ms, next_timeout_ms);
        close(fd);
        return 0;
    }

    if (strcmp(argv[1], "session") == 0) {
        if (argc < 4) {
            usage(argv[0]);
            return 1;
        }

        int baud = atoi(argv[3]);
        int timeout_ms = argc > 4 ? atoi(argv[4]) : 5000;
        int next_timeout_ms = argc > 5 ? atoi(argv[5]) : 1500;
        int fd = open_serial(argv[2], baud);
        drain_input(fd, 200);
        flush_input(fd);
        interactive_session(fd, timeout_ms, next_timeout_ms);
        close(fd);
        return 0;
    }

    usage(argv[0]);
    return 1;
}
