; t72_remque_p1 - VMS's loop that moves every entry of one queue to the tail of
; another (REMQUE @0(R1),R0 / BVS / INSQUE (R0),@4(R2)), headers and
; entries in P1 space (7FFExxxx -> physical 2xxxx), as seen hanging in
; VMS STARTUP on the board. R5 counts the passes (guard).
;@ dump=22680:8
;@ dump=23000:C
	.include "mmsetup.inc"
test:
	movl	#20, r5
	moval	@#^x7FFE2694, r2
	movl	r2, (r2)
	movl	r2, 4(r2)
	moval	@#^x7FFE2684, r1
	movl	r1, (r1)
	movl	r1, 4(r1)
	insque	@#^x7FFE3000, @4(r1)
	insque	@#^x7FFE3010, @4(r1)
	insque	@#^x7FFE3020, @4(r1)
loop:	remque	@0(r1), r0
	bvs	done
	insque	(r0), @4(r2)
	sobgtr	r5, loop
done:	halt
