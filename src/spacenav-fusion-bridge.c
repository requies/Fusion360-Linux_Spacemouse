#include <arpa/inet.h>
#include <errno.h>
#include <signal.h>
#include <spnav.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define DEFAULT_HOST "127.0.0.1"
#define DEFAULT_PORT 39030

static volatile sig_atomic_t keep_running = 1;

static void handle_signal(int signo)
{
    (void)signo;
    keep_running = 0;
}

static void usage(const char *argv0)
{
    fprintf(stderr,
            "Usage: %s [--host ADDR] [--port PORT] [--check]\n"
            "Forward spacenavd events to Fusion's SpacenavBridge add-in over UDP.\n",
            argv0);
}

static int parse_port(const char *value)
{
    char *end = NULL;
    long port = strtol(value, &end, 10);
    if (!value[0] || (end && *end) || port < 1 || port > 65535) {
        return -1;
    }
    return (int)port;
}

static int open_spnav_with_retry(void)
{
    int last_log = 0;

    while (keep_running) {
        if (spnav_open() == 0) {
            return 0;
        }

        if (last_log == 0 || last_log >= 5) {
            fprintf(stderr, "waiting for spacenavd at /run/spnav.sock\n");
            last_log = 0;
        }
        last_log++;
        sleep(1);
    }

    return -1;
}

static int print_check(void)
{
    char name[256] = {0};
    char path[256] = {0};
    unsigned int vendor = 0;
    unsigned int product = 0;

    if (spnav_open() != 0) {
        fprintf(stderr, "failed to connect to spacenavd\n");
        return 1;
    }

    printf("connected to spacenavd protocol %d\n", spnav_protocol());

    if (spnav_dev_name(name, sizeof(name)) > 0) {
        printf("device: %s\n", name);
    }
    if (spnav_dev_path(path, sizeof(path)) > 0) {
        printf("path: %s\n", path);
    }
    printf("axes: %d\n", spnav_dev_axes());
    printf("buttons: %d\n", spnav_dev_buttons());
    if (spnav_dev_usbid(&vendor, &product) == 0) {
        printf("usb: %04x:%04x\n", vendor, product);
    }

    spnav_close();
    return 0;
}

static int send_line(int sock, const struct sockaddr_in *addr, const char *line)
{
    ssize_t sent = sendto(sock, line, strlen(line), 0,
                          (const struct sockaddr *)addr, sizeof(*addr));
    return sent < 0 ? -1 : 0;
}

int main(int argc, char **argv)
{
    const char *host = DEFAULT_HOST;
    int port = DEFAULT_PORT;
    int check_only = 0;
    int sock = -1;
    struct sockaddr_in addr;
    int spnav_socket = -1;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--host") == 0 && i + 1 < argc) {
            host = argv[++i];
        } else if (strcmp(argv[i], "--port") == 0 && i + 1 < argc) {
            port = parse_port(argv[++i]);
            if (port < 0) {
                fprintf(stderr, "invalid port\n");
                return 2;
            }
        } else if (strcmp(argv[i], "--check") == 0) {
            check_only = 1;
        } else if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
            usage(argv[0]);
            return 0;
        } else {
            usage(argv[0]);
            return 2;
        }
    }

    if (check_only) {
        return print_check();
    }

    setvbuf(stderr, NULL, _IOLBF, 0);
    signal(SIGINT, handle_signal);
    signal(SIGTERM, handle_signal);

    sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (sock < 0) {
        perror("socket");
        return 1;
    }

    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);
    if (inet_pton(AF_INET, host, &addr.sin_addr) != 1) {
        fprintf(stderr, "invalid host address: %s\n", host);
        close(sock);
        return 2;
    }

    if (open_spnav_with_retry() != 0) {
        close(sock);
        return 1;
    }

    spnav_client_name("Autodesk Fusion 360 Wine bridge");
    spnav_evmask(SPNAV_EVMASK_INPUT);
    spnav_socket = spnav_fd();
    if (spnav_socket < 0) {
        fprintf(stderr, "spacenavd connection has no file descriptor\n");
        spnav_close();
        close(sock);
        return 1;
    }

    fprintf(stderr, "forwarding spacenavd events to %s:%d\n", host, port);

    while (keep_running) {
        fd_set readfds;
        struct timeval timeout;
        int ready;

        FD_ZERO(&readfds);
        FD_SET(spnav_socket, &readfds);
        timeout.tv_sec = 0;
        timeout.tv_usec = 250000;

        ready = select(spnav_socket + 1, &readfds, NULL, NULL, &timeout);
        if (ready < 0) {
            if (errno == EINTR) {
                continue;
            }
            perror("select");
            break;
        }
        if (ready == 0 || !FD_ISSET(spnav_socket, &readfds)) {
            continue;
        }

        for (;;) {
            spnav_event event;
            int type = spnav_poll_event(&event);
            char line[128];

            if (type == 0) {
                break;
            }

            if (type == SPNAV_EVENT_MOTION) {
                snprintf(line, sizeof(line), "m %d %d %d %d %d %d %u\n",
                         event.motion.x, event.motion.y, event.motion.z,
                         event.motion.rx, event.motion.ry, event.motion.rz,
                         event.motion.period);
                send_line(sock, &addr, line);
            } else if (type == SPNAV_EVENT_BUTTON) {
                snprintf(line, sizeof(line), "b %d %d\n",
                         event.button.press, event.button.bnum);
                send_line(sock, &addr, line);
            }
        }
    }

    spnav_close();
    close(sock);
    return 0;
}
