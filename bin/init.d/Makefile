include ../../defines.mk

all:

SCRIPTS = 		\
	pve-manager 	\
	pvedaemon 	\
	pveproxy 	\
	spiceproxy 	\
	novncproxy	\
	pvebanner	\
	pvestatd	\
	pvenetcommit

.PHONY: install 
install: ${SCRIPTS}
	install -d ${INITDBINDIR}
	install -m 0755 ${SCRIPTS} ${INITDBINDIR}

.PHONY: distclean
distclean: clean

.PHONY: clean
clean:
	rm -rf *~
