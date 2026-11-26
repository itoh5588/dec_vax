; t71_lc_txint - the VAX 8600 console transmit interrupt for a line other
; than the terminal: TXCS written with the write mask, the
; logical console enabled and IE set makes TXCS DONE for line 3 and asks
; for the transmit interrupt (SCB vector FC) at IPL 14, as SIMH's
; txcs_wr/tto_update_int; so does a byte the logical console takes
; (function 03, clear warm start: no answer). The handler counts and
; disables IE.
;@ start=1000
;@ dump=8000:4
	.org	^x1000
	movl	#^x9000, sp
	movl	#txh+1, @#^x20FC	; SCB: transmit, interrupt stack
	mtpr	#^x2000, #^x11		; SCBB
	mtpr	#^x88040, #^x22		; TXCS: WMASK, line 3, IE
	mtpr	#0, #^x12		; IPL 0: the interrupt comes
	movl	#100, r2
w1:	sobgtr	r2, w1
	mtpr	#^x1F, #^x12
	mtpr	#^x40, #^x22		; IE again (line 3 still enabled)
	movl	#100, r2
w2:	sobgtr	r2, w2			; none at IPL 1F
	mtpr	#3, #^x23		; TXDB: clear warm start (to line 3)
	mtpr	#0, #^x12
	movl	#100, r2
w3:	sobgtr	r2, w3
	mtpr	#^x1F, #^x12
	mtpr	#^x18000, #^x22		; back to the terminal, no IE
	mfpr	#^x22, @#^x8008
	clrl	r1
	clrl	r2
	halt
	.align	2
txh:	incl	@#^x8000
	mfpr	#^x22, @#^x8004
	mtpr	#^x0, #^x22		; IE off (enables kept)
	rei
