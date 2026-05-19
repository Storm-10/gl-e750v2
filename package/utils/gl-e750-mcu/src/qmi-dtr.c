/*
 * qmi-dtr: assert DTR on USB interface 4 of Quectel EM060K-GL.
 *
 * Sends SET_CONTROL_LINE_STATE(DTR=1) to USB interface 4 via
 * USBDEVFS_CONTROL. Required to activate the modem's QMI service
 * (replicates QMI_WWAN_QUIRK_DTR which is missing from the static
 * qmi_wwan device table for 2c7c:030b in OpenWrt 25.12).
 *
 * If the kernel driver (qmi_wwan) already holds interface 4, a direct
 * USBDEVFS_CONTROL returns EBUSY. We handle this by temporarily
 * disconnecting the driver, sending DTR, then reconnecting it.
 * This causes cdc-wdm0/wwan0 to briefly disappear and reappear —
 * callers should wait ~2s after this tool exits.
 *
 * Compile with OpenWrt musl toolchain:
 *   $CC -O2 -static -o qmi-dtr qmi-dtr.c
 *
 * Usage:
 *   qmi-dtr /dev/bus/usb/001/004
 *   (find device number: lsusb | grep Quectel)
 */

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <linux/usbdevice_fs.h>

#define IFNUM 4  /* QMI/RMNET interface number on EM060K-GL */

static int send_dtr(int fd)
{
	struct usbdevfs_ctrltransfer ctrl = {
		.bRequestType = 0x21,    /* class | interface | host-to-device */
		.bRequest     = 0x22,    /* SET_CONTROL_LINE_STATE             */
		.wValue       = 0x0001,  /* DTR = 1                            */
		.wIndex       = IFNUM,
		.wLength      = 0,
		.timeout      = 1000,
		.data         = NULL,
	};
	return ioctl(fd, USBDEVFS_CONTROL, &ctrl);
}

int main(int argc, char **argv)
{
	if (argc < 2) {
		fprintf(stderr, "usage: %s /dev/bus/usb/<bus>/<dev>\n", argv[0]);
		fprintf(stderr, "  find device: lsusb | grep Quectel\n");
		return 1;
	}

	int fd = open(argv[1], O_RDWR);
	if (fd < 0) {
		perror(argv[1]);
		return 1;
	}

	/* Try direct control transfer first (works right after new_id,
	 * before qmi_wwan fully claims the interface). */
	if (send_dtr(fd) == 0) {
		printf("DTR asserted on %s interface %d\n", argv[1], IFNUM);
		close(fd);
		return 0;
	}

	if (errno != EBUSY) {
		perror("USBDEVFS_CONTROL");
		close(fd);
		return 1;
	}

	/* Interface is held by qmi_wwan. Disconnect driver, claim interface,
	 * send DTR, release, reconnect. cdc-wdm0/wwan0 will briefly vanish. */
	fprintf(stderr, "interface busy, using disconnect/reconnect\n");

	unsigned int ifnum = IFNUM;

	/* Detach kernel driver from interface 4.
	 * Must go via USBDEVFS_IOCTL — that targets a specific interface.
	 * Direct USBDEVFS_DISCONNECT/CONNECT without USBDEVFS_IOCTL wrapper
	 * operate on the whole device and return ENOTTY on interface args. */
	struct usbdevfs_ioctl disc = {
		.ifno        = IFNUM,
		.ioctl_code  = USBDEVFS_DISCONNECT,
		.data        = NULL,
	};
	if (ioctl(fd, USBDEVFS_IOCTL, &disc) < 0) {
		perror("USBDEVFS_IOCTL(DISCONNECT)");
		close(fd);
		return 1;
	}

	if (ioctl(fd, USBDEVFS_CLAIMINTERFACE, &ifnum) < 0) {
		perror("USBDEVFS_CLAIMINTERFACE");
		struct usbdevfs_ioctl conn = { .ifno = IFNUM,
		                               .ioctl_code = USBDEVFS_CONNECT };
		ioctl(fd, USBDEVFS_IOCTL, &conn);
		close(fd);
		return 1;
	}

	int ret = send_dtr(fd);
	int saved_errno = errno;

	ioctl(fd, USBDEVFS_RELEASEINTERFACE, &ifnum);
	struct usbdevfs_ioctl conn = {
		.ifno       = IFNUM,
		.ioctl_code = USBDEVFS_CONNECT,
		.data       = NULL,
	};
	ioctl(fd, USBDEVFS_IOCTL, &conn);
	close(fd);

	if (ret < 0) {
		errno = saved_errno;
		perror("USBDEVFS_CONTROL");
		return 1;
	}

	printf("DTR asserted on %s interface %d (via disconnect/reconnect)\n",
	       argv[1], IFNUM);
	return 0;
}
