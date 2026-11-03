/*
 * sk-icloud-keychain: OpenSSH security key provider backed by iCloud Keychain.
 *
 * The provider is loaded by ssh-sk-helper via SecurityKeyProvider. It has no
 * entitlements, so it forwards each request to the signed helper app, which
 * owns the keychain items and the Touch ID check. See docs/protocol.md.
 */

#include <sys/wait.h>

#define __STDC_WANT_LIB_EXT1__ 1
#include <dlfcn.h>
#include <errno.h>
#include <signal.h>
#include <spawn.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "sk-api.h"

#define EXPORT __attribute__((visibility("default")))

#define HELPER_ENV	"SK_ICLOUD_KEYCHAIN_HELPER"
#define HELPER_REL	"sk-icloud-keychain.app/Contents/MacOS/sk-icloud-keychain"
#define USER_ID_LEN	32	/* matches sk-usbhid */
#define MAX_RESPONSE	(1024 * 1024)

extern char **environ;

struct buf {
	char *data;
	size_t len;
	size_t cap;
};

static void
skdebug(const char *func, const char *fmt, ...)
{
	va_list ap;

	if (getenv("SK_ICLOUD_KEYCHAIN_DEBUG") == NULL)
		return;
	va_start(ap, fmt);
	fprintf(stderr, "sk-icloud-keychain: %s: ", func);
	vfprintf(stderr, fmt, ap);
	fputc('\n', stderr);
	va_end(ap);
}

static int
buf_append(struct buf *b, const void *p, size_t len)
{
	char *n;
	size_t cap;

	if (b->len + len + 1 > b->cap) {
		cap = b->cap ? b->cap : 256;
		while (b->len + len + 1 > cap)
			cap *= 2;
		if ((n = realloc(b->data, cap)) == NULL)
			return -1;
		b->data = n;
		b->cap = cap;
	}
	memcpy(b->data + b->len, p, len);
	b->len += len;
	b->data[b->len] = '\0';
	return 0;
}

static void
buf_free(struct buf *b)
{
	if (b->data != NULL)
		memset_s(b->data, b->cap, 0, b->cap);
	free(b->data);
	memset(b, 0, sizeof(*b));
}

static int
add_str(struct buf *b, const char *key, const char *value)
{
	if (strchr(value, '\n') != NULL)
		return -1;
	if (buf_append(b, key, strlen(key)) != 0 || buf_append(b, "=", 1) != 0 ||
	    buf_append(b, value, strlen(value)) != 0 || buf_append(b, "\n", 1) != 0)
		return -1;
	return 0;
}

static int
add_hex(struct buf *b, const char *key, const uint8_t *p, size_t len)
{
	static const char digits[] = "0123456789abcdef";
	char pair[2];
	size_t i;

	if (buf_append(b, key, strlen(key)) != 0 || buf_append(b, "=", 1) != 0)
		return -1;
	for (i = 0; i < len; i++) {
		pair[0] = digits[p[i] >> 4];
		pair[1] = digits[p[i] & 0xf];
		if (buf_append(b, pair, 2) != 0)
			return -1;
	}
	return buf_append(b, "\n", 1);
}

/* Returns the value of `key` in a key=value response, or NULL. */
static const char *
field(const struct buf *resp, const char *key, size_t *lenp)
{
	const char *p = resp->data, *end, *eq;
	size_t klen = strlen(key);

	while (p != NULL && *p != '\0') {
		end = strchr(p, '\n');
		eq = memchr(p, '=', end ? (size_t)(end - p) : strlen(p));
		if (eq != NULL && (size_t)(eq - p) == klen &&
		    memcmp(p, key, klen) == 0) {
			*lenp = end ? (size_t)(end - eq - 1) : strlen(eq + 1);
			return eq + 1;
		}
		p = end ? end + 1 : NULL;
	}
	return NULL;
}

static int
nibble(char c)
{
	if (c >= '0' && c <= '9')
		return c - '0';
	if (c >= 'a' && c <= 'f')
		return c - 'a' + 10;
	if (c >= 'A' && c <= 'F')
		return c - 'A' + 10;
	return -1;
}

/* Decodes hex field `key` into a newly allocated buffer. */
static int
field_bytes(const struct buf *resp, const char *key, uint8_t **out, size_t *outlen)
{
	const char *v;
	size_t vlen, i;
	int hi, lo;

	*out = NULL;
	*outlen = 0;
	if ((v = field(resp, key, &vlen)) == NULL || vlen % 2 != 0) {
		skdebug(__func__, "missing or malformed field %s", key);
		return -1;
	}
	if ((*out = calloc(1, vlen / 2 + 1)) == NULL)
		return -1;
	for (i = 0; i < vlen / 2; i++) {
		if ((hi = nibble(v[2 * i])) < 0 || (lo = nibble(v[2 * i + 1])) < 0) {
			free(*out);
			*out = NULL;
			skdebug(__func__, "bad hex in field %s", key);
			return -1;
		}
		(*out)[i] = (uint8_t)(hi << 4 | lo);
	}
	*outlen = vlen / 2;
	return 0;
}

static int
field_byte(const struct buf *resp, const char *key, uint8_t *out)
{
	uint8_t *p;
	size_t len;

	if (field_bytes(resp, key, &p, &len) != 0)
		return -1;
	if (len != 1) {
		free(p);
		return -1;
	}
	*out = p[0];
	free(p);
	return 0;
}

static int
field_ulong(const struct buf *resp, const char *key, unsigned long *out)
{
	char tmp[32], *ep;
	const char *v;
	size_t vlen;

	if ((v = field(resp, key, &vlen)) == NULL || vlen == 0 ||
	    vlen >= sizeof(tmp))
		return -1;
	memcpy(tmp, v, vlen);
	tmp[vlen] = '\0';
	errno = 0;
	*out = strtoul(tmp, &ep, 10);
	return (errno != 0 || *ep != '\0') ? -1 : 0;
}

static int
helper_path(char *path, size_t len)
{
	const char *env, *home;

	Dl_info info;
	char *slash;

	if ((env = getenv(HELPER_ENV)) != NULL && *env != '\0') {
		snprintf(path, len, "%s", env);
		return access(path, X_OK);
	}
	/* Embedded in the app: <app>/Contents/Frameworks/<this dylib> */
	if (dladdr((const void *)helper_path, &info) != 0 &&
	    info.dli_fname != NULL &&
	    snprintf(path, len, "%s", info.dli_fname) < (int)len &&
	    (slash = strrchr(path, '/')) != NULL) {
		*slash = '\0';
		if ((slash = strrchr(path, '/')) != NULL &&
		    strcmp(slash, "/Frameworks") == 0) {
			*slash = '\0';
			if (strlcat(path, "/MacOS/sk-icloud-keychain", len) < len &&
			    access(path, X_OK) == 0)
				return 0;
		}
	}
	snprintf(path, len, "/Applications/%s", HELPER_REL);
	if (access(path, X_OK) == 0)
		return 0;
	if ((home = getenv("HOME")) != NULL) {
		snprintf(path, len, "%s/Applications/%s", home, HELPER_REL);
		if (access(path, X_OK) == 0)
			return 0;
	}
	return -1;
}

static int
write_all(int fd, const char *p, size_t len)
{
	ssize_t n;

	while (len > 0) {
		if ((n = write(fd, p, len)) < 0) {
			if (errno == EINTR)
				continue;
			return -1;
		}
		p += n;
		len -= (size_t)n;
	}
	return 0;
}

/*
 * Runs `helper <command>` with fresh pipes (our own stdin/stdout belong to
 * ssh-sk-helper's protocol), sends `req` and collects the response.
 * Returns 0 or an SSH_SK_ERR_* code.
 */
static int
run_helper(const char *command, const struct buf *req, struct buf *resp)
{
	char path[1024], chunk[4096], *argv[3];
	int in[2] = { -1, -1 }, out[2] = { -1, -1 };
	int ret = SSH_SK_ERR_GENERAL, status, wrote;
	posix_spawn_file_actions_t fa;
	struct sigaction sa, osa;
	const char *st;
	size_t stlen;
	ssize_t n;
	pid_t pid;

	if (helper_path(path, sizeof(path)) != 0) {
		skdebug(__func__, "helper app not found (install it in "
		    "/Applications or set %s)", HELPER_ENV);
		return SSH_SK_ERR_DEVICE_NOT_FOUND;
	}
	skdebug(__func__, "%s %s", path, command);
	if (pipe(in) != 0 || pipe(out) != 0) {
		skdebug(__func__, "pipe: %s", strerror(errno));
		goto out;
	}
	posix_spawn_file_actions_init(&fa);
	posix_spawn_file_actions_adddup2(&fa, in[0], STDIN_FILENO);
	posix_spawn_file_actions_adddup2(&fa, out[1], STDOUT_FILENO);
	posix_spawn_file_actions_addclose(&fa, in[1]);
	posix_spawn_file_actions_addclose(&fa, out[0]);
	argv[0] = path;
	argv[1] = (char *)command;
	argv[2] = NULL;
	status = posix_spawn(&pid, path, &fa, NULL, argv, environ);
	posix_spawn_file_actions_destroy(&fa);
	if (status != 0) {
		skdebug(__func__, "posix_spawn: %s", strerror(status));
		goto out;
	}
	close(in[0]);
	close(out[1]);
	in[0] = out[1] = -1;

	/* Don't let a dying helper kill ssh-sk-helper with SIGPIPE. */
	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = SIG_IGN;
	sigaction(SIGPIPE, &sa, &osa);
	wrote = req->len == 0 ? 0 : write_all(in[1], req->data, req->len);
	sigaction(SIGPIPE, &osa, NULL);
	close(in[1]);
	in[1] = -1;

	for (;;) {
		if ((n = read(out[0], chunk, sizeof(chunk))) < 0) {
			if (errno == EINTR)
				continue;
			break;
		}
		if (n == 0 || resp->len + (size_t)n > MAX_RESPONSE ||
		    buf_append(resp, chunk, (size_t)n) != 0)
			break;
	}
	while (waitpid(pid, &status, 0) < 0 && errno == EINTR)
		;
	if (wrote != 0) {
		skdebug(__func__, "failed to send request to helper");
		goto out;
	}
	if ((st = field(resp, "status", &stlen)) != NULL &&
	    stlen == 2 && memcmp(st, "ok", 2) == 0) {
		ret = 0;
		goto out;
	}
	/* error=-N carries an SSH_SK_ERR_* code */
	if ((st = field(resp, "error", &stlen)) != NULL && stlen == 2 &&
	    st[0] == '-' && st[1] >= '1' && st[1] <= '5')
		ret = -(st[1] - '0');
	if ((st = field(resp, "message", &stlen)) != NULL)
		skdebug(__func__, "helper: %.*s", (int)stlen, st);
	else
		skdebug(__func__, "helper exited with status %d and no "
		    "response", status);
 out:
	if (in[0] != -1)
		close(in[0]);
	if (in[1] != -1)
		close(in[1]);
	if (out[0] != -1)
		close(out[0]);
	if (out[1] != -1)
		close(out[1]);
	return ret;
}

/* Accepts the options sk-usbhid accepts; returns user (may be NULL). */
static int
check_options(struct sk_option **options, const char **user)
{
	size_t i;

	*user = NULL;
	if (options == NULL)
		return 0;
	for (i = 0; options[i] != NULL; i++) {
		if (strcmp(options[i]->name, "user") == 0) {
			if (strlen(options[i]->value) >= USER_ID_LEN) {
				skdebug(__func__, "user too long");
				return -1;
			}
			*user = options[i]->value;
		} else if (strcmp(options[i]->name, "device") == 0) {
			skdebug(__func__, "ignoring device option");
		} else {
			skdebug(__func__, "unsupported option %s",
			    options[i]->name);
			if (options[i]->required)
				return -1;
		}
	}
	return 0;
}

static void
free_enroll_fields(struct sk_enroll_response *r)
{
	free(r->public_key);
	free(r->key_handle);
	free(r->signature);
	free(r->attestation_cert);
	free(r->authdata);
}

EXPORT uint32_t
sk_api_version(void)
{
	return SSH_SK_VERSION_MAJOR;
}

EXPORT int
sk_enroll(uint32_t alg, const uint8_t *challenge, size_t challenge_len,
    const char *application, uint8_t flags, const char *pin,
    struct sk_option **options, struct sk_enroll_response **enroll_response)
{
	struct sk_enroll_response *response = NULL;
	struct buf req = { 0 }, resp = { 0 };
	const char *user;
	int ret = SSH_SK_ERR_GENERAL;

	if (enroll_response == NULL)
		return SSH_SK_ERR_GENERAL;
	*enroll_response = NULL;
	if (alg != SSH_SK_ED25519) {
		skdebug(__func__, "unsupported key type %u", alg);
		return SSH_SK_ERR_UNSUPPORTED;
	}
	if (check_options(options, &user) != 0)
		return SSH_SK_ERR_GENERAL;
	if (add_str(&req, "application", application) != 0 ||
	    add_hex(&req, "flags", &flags, 1) != 0 ||
	    (user != NULL && add_hex(&req, "user",
	    (const uint8_t *)user, strlen(user)) != 0))
		goto out;
	if ((ret = run_helper("enroll", &req, &resp)) != 0)
		goto out;
	ret = SSH_SK_ERR_GENERAL;
	if ((response = calloc(1, sizeof(*response))) == NULL ||
	    field_bytes(&resp, "public_key", &response->public_key,
	    &response->public_key_len) != 0 ||
	    field_bytes(&resp, "key_handle", &response->key_handle,
	    &response->key_handle_len) != 0 ||
	    field_byte(&resp, "flags", &response->flags) != 0)
		goto out;
	/* No attestation; OpenSSH still expects a non-NULL signature. */
	if ((response->signature = calloc(1, 1)) == NULL)
		goto out;
	*enroll_response = response;
	response = NULL;
	ret = 0;
 out:
	if (response != NULL) {
		free_enroll_fields(response);
		free(response);
	}
	buf_free(&req);
	buf_free(&resp);
	return ret;
}

EXPORT int
sk_sign(uint32_t alg, const uint8_t *data, size_t data_len,
    const char *application, const uint8_t *key_handle, size_t key_handle_len,
    uint8_t flags, const char *pin, struct sk_option **options,
    struct sk_sign_response **sign_response)
{
	struct sk_sign_response *response = NULL;
	struct buf req = { 0 }, resp = { 0 };
	unsigned long counter;
	const char *user;
	int ret = SSH_SK_ERR_GENERAL;

	if (sign_response == NULL)
		return SSH_SK_ERR_GENERAL;
	*sign_response = NULL;
	if (alg != SSH_SK_ED25519) {
		skdebug(__func__, "unsupported key type %u", alg);
		return SSH_SK_ERR_UNSUPPORTED;
	}
	if (check_options(options, &user) != 0)
		return SSH_SK_ERR_GENERAL;
	if (add_str(&req, "application", application) != 0 ||
	    add_hex(&req, "key_handle", key_handle, key_handle_len) != 0 ||
	    add_hex(&req, "flags", &flags, 1) != 0 ||
	    add_hex(&req, "data", data, data_len) != 0)
		goto out;
	if ((ret = run_helper("sign", &req, &resp)) != 0)
		goto out;
	ret = SSH_SK_ERR_GENERAL;
	if ((response = calloc(1, sizeof(*response))) == NULL ||
	    field_bytes(&resp, "signature", &response->sig_r,
	    &response->sig_r_len) != 0 ||
	    field_byte(&resp, "flags", &response->flags) != 0 ||
	    field_ulong(&resp, "counter", &counter) != 0 ||
	    counter > UINT32_MAX)
		goto out;
	response->counter = (uint32_t)counter;
	*sign_response = response;
	response = NULL;
	ret = 0;
 out:
	if (response != NULL) {
		free(response->sig_r);
		free(response->sig_s);
		free(response);
	}
	buf_free(&req);
	buf_free(&resp);
	return ret;
}

EXPORT int
sk_load_resident_keys(const char *pin, struct sk_option **options,
    struct sk_resident_key ***rksp, size_t *nrksp)
{
	struct sk_resident_key **rks = NULL, *rk;
	struct buf req = { 0 }, resp = { 0 };
	unsigned long count, i;
	char key[64];
	const char *user, *v;
	uint8_t *uid;
	size_t vlen, uidlen;
	int ret = SSH_SK_ERR_GENERAL;

	if (rksp == NULL || nrksp == NULL)
		return SSH_SK_ERR_GENERAL;
	*rksp = NULL;
	*nrksp = 0;
	if (check_options(options, &user) != 0)
		return SSH_SK_ERR_GENERAL;
	if ((ret = run_helper("list", &req, &resp)) != 0)
		goto out;
	ret = SSH_SK_ERR_GENERAL;
	if (field_ulong(&resp, "count", &count) != 0 || count > 10000 ||
	    (rks = calloc(count + 1, sizeof(*rks))) == NULL)
		goto out;
	for (i = 0; i < count; i++) {
		if ((rk = rks[i] = calloc(1, sizeof(*rk))) == NULL)
			goto out;
		rk->alg = SSH_SK_ED25519;
		rk->slot = i;
		snprintf(key, sizeof(key), "%lu.application", i);
		if ((v = field(&resp, key, &vlen)) == NULL ||
		    (rk->application = strndup(v, vlen)) == NULL)
			goto out;
		snprintf(key, sizeof(key), "%lu.public_key", i);
		if (field_bytes(&resp, key, &rk->key.public_key,
		    &rk->key.public_key_len) != 0)
			goto out;
		snprintf(key, sizeof(key), "%lu.key_handle", i);
		if (field_bytes(&resp, key, &rk->key.key_handle,
		    &rk->key.key_handle_len) != 0)
			goto out;
		snprintf(key, sizeof(key), "%lu.flags", i);
		if (field_byte(&resp, key, &rk->flags) != 0)
			goto out;
		rk->key.flags = rk->flags;
		/* Fixed-size, zero-padded user id like sk-usbhid. */
		if ((rk->user_id = calloc(1, USER_ID_LEN)) == NULL)
			goto out;
		rk->user_id_len = USER_ID_LEN;
		snprintf(key, sizeof(key), "%lu.user", i);
		if (field(&resp, key, &vlen) != NULL) {
			if (field_bytes(&resp, key, &uid, &uidlen) != 0)
				goto out;
			memcpy(rk->user_id, uid,
			    uidlen < USER_ID_LEN ? uidlen : USER_ID_LEN);
			free(uid);
		}
		(*nrksp)++;
	}
	*rksp = rks;
	rks = NULL;
	ret = 0;
 out:
	if (rks != NULL) {
		for (i = 0; rks[i] != NULL; i++) {
			free(rks[i]->application);
			free_enroll_fields(&rks[i]->key);
			free(rks[i]->user_id);
			free(rks[i]);
		}
		free(rks);
		*nrksp = 0;
	}
	buf_free(&req);
	buf_free(&resp);
	return ret;
}
