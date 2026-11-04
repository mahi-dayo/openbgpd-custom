# Native 9.3 uses a newer imsg ABI than OpenBSD 7.9's system libutil.
# Compile the matching, unmodified upstream imsg implementation privately.
.PATH: ${.CURDIR}/../../lib/libutil
SRCS+= imsg.c imsg-buffer.c
CFLAGS+= -I${.CURDIR}/../../lib/libutil
