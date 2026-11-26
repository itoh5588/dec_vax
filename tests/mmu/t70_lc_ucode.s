; t70_lc_ucode - the VAX 8600 console subchannels: enable only
; the logical console (TXCS<19>, write mask TXCS<15>), wait for TXCS<7>
; with TXCS<11:8> = 3, ask for the microcode version (function 12), take
; the three bytes of the answer from RXDB (RXDB<11:8> = 3), and give the
; transmitter back to the console terminal. As VMS's SYSBOOT does.
;@ start=1000
;@ dump=8000:6
	.org	^x1000
	mtpr	#^x88000, #^x22		; TXCS: WMASK, enable line 3 only
w1:	mfpr	#^x22, r1
	bbc	#7, r1, w1
	movl	r1, @#^x8000		; 00080380: enable 3, ID 3, done
	mtpr	#^x12, #^x23		; TXDB: microcode version
	movl	#3, r2
	movl	#^x8004, r3
w2:	mfpr	#^x20, r0		; RXCS
	bbc	#7, r0, w2
	mfpr	#^x21, r0		; RXDB
	movl	r0, (r3)+
	sobgtr	r2, w2
	mtpr	#^x18000, #^x22		; TXCS: enable line 0 only
w3:	mfpr	#^x22, r1
	bbc	#7, r1, w3
	movl	r1, @#^x8010		; 00010080: enable 0, ID 0, done
	clrl	r0
	clrl	r1
	halt
