# HTTP workers: one epoll loop per thread with its own listening socket and fd table.
.include "defs.inc"
# Per-request frame, addressed through r14.
.set R_METHOD,0        # 1 GET 2 POST 3 PUT 4 DELETE
.set R_PATH,8
.set R_PATHLEN,16
.set R_QUERY,24
.set R_QLEN,32
.set R_AUTH,40
.set R_AUTHLEN,48
.set R_BODY,56
.set R_BODYLEN,64
.set R_CLOSE,72
.set R_VIEWER,80
.set R_TOK,88
.set R_TOKLEN,96
.set R_TOTAL,104
.set R_FD,112
.set R_OBJ,120
.set R_OBJEND,128
.set R_SEGS,136        # 5 (ptr,len)
.set R_NSEGS,216
.set R_GZ,232
.set R_CUR,224         # job string cursor
.set R_SIZE,256
.set M_GET,1
.set M_POST,2
.set M_PUT,3
.set M_DEL,4
.set F_REQ,1           # field must be present
.set F_NONEMPTY,2      # field, when present, must not be empty
.text

# ---- connection plumbing. r15 worker throughout.
# conn_of edi fd -> rax conn
.macro CONN_OF fd,out
  mov \out,\fd
  shl \out,6
  add \out,[r15+W_CONNS]
.endm

close_conn:            # edi fd. Bumps gen so late job completions are dropped.
  push rbx
  push r12
  mov r12d,edi
  CONN_OF r12,rbx
  inc dword ptr [rbx+C_GEN]
  mov dword ptr [rbx+C_BUSY],0
  mov dword ptr [rbx+C_CLOSING],0
  mov rdi,[rbx+C_IN]
  call free
  mov rdi,[rbx+C_OUT]
  call free
  xor eax,eax
  mov [rbx+C_IN],rax
  mov [rbx+C_INLEN],rax
  mov [rbx+C_OUT],rax
  mov edi,r12d
  SYS SYS_CLOSE
  pop r12
  pop rbx
  ret

# conn_send edi fd, rsi data, rdx len. Copies what the socket will not take now.
conn_send:
  push rbx
  push r12
  push r13
  mov r12d,edi
  mov r13,rsi
  mov rbx,rdx
1:mov edi,r12d
  mov rsi,r13
  mov rdx,rbx
  SYS SYS_WRITE
  cmp rax,-4
  je 1b
  cmp rax,-11
  je 2f
  test rax,rax
  js 8f
  add r13,rax
  sub rbx,rax
  jz 7f
  jmp 1b
2:# socket full: keep the rest and watch for EPOLLOUT
  lea rdi,[rbx+16]
  call alloc
  mov rdi,rax
  mov rsi,r13
  mov rcx,rbx
  push rax
  call mcpy
  pop rax
  mov rcx,r12
  shl rcx,6
  add rcx,[r15+W_CONNS]
  mov [rcx+C_OUT],rax
  mov qword ptr [rcx+C_OUTOFF],0
  mov [rcx+C_OUTLEN],rbx
  mov esi,3              # EPOLL_CTL_MOD
  mov edx,0x2005         # IN|OUT|RDHUP
  mov edi,r12d
  call ep_ctl
7:pop r13
  pop r12
  pop rbx
  ret
8:mov edi,r12d
  pop r13
  pop r12
  pop rbx
  jmp close_conn

# ep_ctl edi fd, esi op, edx events
ep_ctl:
  sub rsp,16
  mov [rsp],edx
  mov [rsp+4],edi
  mov dword ptr [rsp+8],0
  mov edx,edi
  mov edi,[r15+W_EPFD]
  mov r10,rsp
  SYS SYS_EPOLL_CTL
  add rsp,16
  ret

# ---- worker loop
.globl worker_main
worker_main:
  mov r15,rdi
  mov edi,0x400          # CLONE_FILES: a private fd table for this loop
  SYS SYS_UNSHARE
  mov edi,RBUF_SIZE+64
  call mmap_anon
  mov [r15+W_RBUF],rax
  mov rdi,C_SIZE*MAX_FDS
  call mmap_anon
  mov [r15+W_CONNS],rax
  sub rsp,12*1024+R_SIZE+64
  lea r14,[rsp+12*1024]
.Lwloop:
  mov edi,[r15+W_EPFD]
  mov rsi,rsp
  mov edx,1024
  mov r10,-1
  SYS SYS_EPOLL_WAIT
  test rax,rax
  jle .Lwloop
  mov r12,rax
  call now_s
  mov [r15+W_NOW_S],rax
  call now_ms
  mov [r15+W_NOW_MS],rax
  xor r13d,r13d
.Lwev:
  lea rax,[r13+r13*2]
  mov ebx,[rsp+rax*4]    # events
  mov ebp,[rsp+rax*4+4]  # fd
  cmp ebp,[r15+W_LISTEN]
  je .Lwaccept
  cmp ebp,[r15+W_EVFD]
  je .Lwinbox
  # EPOLLOUT first
  test ebx,4
  jz 1f
  mov edi,ebp
  call conn_flush
1:test ebx,0x2019       # IN|ERR|HUP|RDHUP
  jz .Lwnext
  mov edi,ebp
  call conn_read
.Lwnext:
  inc r13
  cmp r13,r12
  jne .Lwev
  jmp .Lwloop
.Lwaccept:
  call do_accept
  jmp .Lwnext
.Lwinbox:
  call drain_inbox
  jmp .Lwnext

do_accept:
  push rbx
  mov ebx,256
1:mov edi,[r15+W_LISTEN]
  xor esi,esi
  xor edx,edx
  mov r10d,0x80800       # NONBLOCK|CLOEXEC
  SYS SYS_ACCEPT4
  test rax,rax
  js 3f
  cmp rax,MAX_FDS
  jae 4f
  mov edi,eax
  mov esi,1              # ADD
  mov edx,0x2001         # IN|RDHUP
  call ep_ctl
  dec ebx
  jnz 1b
2:pop rbx
  ret
3:cmp rax,-11
  je 2b
  # out of fds or similar: back off instead of spinning on the level-triggered listener
  sub rsp,16
  mov qword ptr [rsp],0
  mov qword ptr [rsp+8],1000000
  mov rdi,rsp
  xor esi,esi
  SYS SYS_NANOSLEEP
  add rsp,16
  jmp 2b
4:mov edi,eax
  SYS SYS_CLOSE
  jmp 1b

# conn_flush edi fd: EPOLLOUT
conn_flush:
  push rbx
  push r12
  mov r12d,edi
  CONN_OF r12,rbx
  cmp qword ptr [rbx+C_OUT],0
  je 9f
1:mov edi,r12d
  mov rsi,[rbx+C_OUT]
  add rsi,[rbx+C_OUTOFF]
  mov rdx,[rbx+C_OUTLEN]
  SYS SYS_WRITE
  cmp rax,-4
  je 1b
  cmp rax,-11
  je 9f
  test rax,rax
  js 8f
  add [rbx+C_OUTOFF],rax
  sub [rbx+C_OUTLEN],rax
  jnz 1b
  mov rdi,[rbx+C_OUT]
  call free
  mov qword ptr [rbx+C_OUT],0
  mov edi,r12d
  mov esi,3
  mov edx,0x2001
  call ep_ctl
  cmp dword ptr [rbx+C_CLOSING],0
  jne 8f
  mov edi,r12d
  call conn_resume
9:pop r12
  pop rbx
  ret
8:mov edi,r12d
  pop r12
  pop rbx
  jmp close_conn

# drain_inbox: answers every finished job
drain_inbox:
  push rbx
  push r12
  push r13
  sub rsp,16
  mov edi,[r15+W_EVFD]
  mov rsi,rsp
  mov edx,8
  SYS SYS_READ
  mov dword ptr [r15+W_NOTIFIED],0
  xor eax,eax
  xchg rax,[r15+W_INBOX]
  mov rbx,rax
1:test rbx,rbx
  jz 9f
  mov r12d,[rbx+J_FD]
  CONN_OF r12,r13
  mov eax,[rbx+J_GEN]
  cmp eax,[r13+C_GEN]
  jne 5f
  mov dword ptr [r13+C_BUSY],0
  mov edi,r12d
  mov rsi,[rbx+J_RESP]
  add rsi,[rbx+J_RESPOFF]
  mov rdx,[rbx+J_RESPLEN]
  mov eax,[r13+C_GEN]
  push rax
  call conn_send
  pop rax
  cmp eax,[r13+C_GEN]
  jne 5f                 # the send failed and closed it
  cmp dword ptr [r13+C_CLOSING],0
  je 3f
  cmp qword ptr [r13+C_OUT],0
  jne 5f                 # close after the flush
  mov edi,r12d
  call close_conn
  jmp 5f
3:mov edi,r12d
  call conn_resume
5:mov r12,[rbx+J_NEXT]
  mov rdi,[rbx+J_EXTRA]
  call free
  mov rdi,[rbx+J_RESP]
  call free
  mov rdi,rbx
  call free
  mov rbx,r12
  jmp 1b
9:add rsp,16
  pop r13
  pop r12
  pop rbx
  ret

# conn_read edi fd
conn_read:
  push rbx
  push r12
  mov r12d,edi
  CONN_OF r12,rbx
  cmp qword ptr [rbx+C_IN],0
  jne .Lappend
  # common case: the request sits in the shared read buffer
  mov edi,r12d
  mov rsi,[r15+W_RBUF]
  mov edx,RBUF_SIZE
  SYS SYS_READ
  cmp rax,-11
  je .Lrd_done
  cmp rax,-4
  je .Lrd_done
  test rax,rax
  jle .Lrd_close
  mov edi,r12d
  mov rsi,[r15+W_RBUF]
  mov rdx,rax
  call conn_process
.Lrd_done:
  pop r12
  pop rbx
  ret
.Lrd_close:
  mov edi,r12d
  pop r12
  pop rbx
  jmp close_conn
.Lappend:
  # grow the pending buffer if a full read might not fit
  mov eax,[rbx+C_INLEN]
  add eax,RBUF_SIZE
  cmp eax,[rbx+C_INCAP]
  jbe 2f
  cmp eax,MAX_BODY+RBUF_SIZE*3
  ja .Lrd_close
  lea edi,[rax+rax]
  mov [rbx+C_INCAP],edi
  call alloc
  push rax
  mov rdi,rax
  mov rsi,[rbx+C_IN]
  mov ecx,[rbx+C_INLEN]
  call mcpy
  mov rdi,[rbx+C_IN]
  call free
  pop rax
  mov [rbx+C_IN],rax
2:mov edi,r12d
  mov rsi,[rbx+C_IN]
  mov eax,[rbx+C_INLEN]
  add rsi,rax
  mov edx,RBUF_SIZE
  SYS SYS_READ
  cmp rax,-11
  je .Lrd_done
  cmp rax,-4
  je .Lrd_done
  test rax,rax
  jle .Lrd_close
  add [rbx+C_INLEN],eax
  cmp dword ptr [rbx+C_BUSY],0
  jne .Lrd_done
  cmp qword ptr [rbx+C_OUT],0
  jne .Lrd_done
  mov edi,r12d
  call conn_resume
  jmp .Lrd_done

# conn_resume edi fd: parse whatever is pending
conn_resume:
  mov eax,edi
  shl rax,6
  add rax,[r15+W_CONNS]
  mov rsi,[rax+C_IN]
  test rsi,rsi
  jz 1f
  mov edx,[rax+C_INLEN]
  test edx,edx
  jz 1f
  jmp conn_process
1:ret

# conn_process edi fd, rsi data, rdx len. data is the read buffer or the conn's own pending buffer.
conn_process:
  push rbx
  push rbp
  push r12
  push r13
  mov r12d,edi
  CONN_OF r12,rbx
  mov r13,rsi            # cursor
  mov rbp,rdx            # bytes left
  mov [r14+R_FD],r12
  mov eax,[rbx+C_GEN]
  push rax
.Lproc:
  test rbp,rbp
  jz .Lleft
  cmp dword ptr [rbx+C_BUSY],0
  jne .Lleft
  cmp qword ptr [rbx+C_OUT],0
  jne .Lleft
  mov rdi,r13
  mov rsi,rbp
  call parse_request     # rax = bytes of this request, 0 when incomplete, -1 when malformed
  test rax,rax
  jz .Lleft
  js .Lproc_bad
  add r13,rax
  sub rbp,rax
  mov [r14+R_TOTAL],rax
  call route
  mov eax,[rsp]
  cmp eax,[rbx+C_GEN]
  jne .Lproc_end         # closed while answering
  cmp qword ptr [r14+R_CLOSE],0
  je .Lproc
  # Connection: close
  mov dword ptr [rbx+C_CLOSING],1
  cmp dword ptr [rbx+C_BUSY],0
  jne .Lleft
  cmp qword ptr [rbx+C_OUT],0
  jne .Lleft
  mov edi,r12d
  call close_conn
  jmp .Lproc_end
.Lproc_bad:
  mov esi,422
  call reply_err
  mov edi,r12d
  call close_conn
  jmp .Lproc_end
.Lleft:
  # keep what was not consumed
  mov rax,[rbx+C_IN]
  test rax,rax
  jz .Lstash
  # already in the pending buffer: slide down
  mov [rbx+C_INLEN],ebp
  test rbp,rbp
  jz .Lfree_in
  cmp rax,r13
  je .Lproc_end
  mov rdi,rax
  mov rsi,r13
  mov rcx,rbp
  rep movsb
  jmp .Lproc_end
.Lfree_in:
  mov rdi,rax
  call free
  mov qword ptr [rbx+C_IN],0
  mov dword ptr [rbx+C_INCAP],0
  jmp .Lproc_end
.Lstash:
  test rbp,rbp
  jz .Lproc_end
  lea rdi,[rbp+RBUF_SIZE*2]
  mov [rbx+C_INCAP],edi
  call alloc
  mov [rbx+C_IN],rax
  mov [rbx+C_INLEN],ebp
  mov rdi,rax
  mov rsi,r13
  mov rcx,rbp
  call mcpy
.Lproc_end:
  add rsp,8
  pop r13
  pop r12
  pop rbp
  pop rbx
  ret

# ---- request parsing
.section .rodata
.balign 16
x_cr: .fill 16,1,13
.text
# ieq: compare rdi[0..rcx) case-insensitively with lowercase rsi. ZF when equal.
ieq:
  test rcx,rcx
  jz 2f
1:mov al,[rdi]
  cmp al,'A'
  jb 3f
  cmp al,'Z'
  ja 3f
  or al,0x20
3:cmp al,[rsi]
  jne 2f
  inc rdi
  inc rsi
  dec rcx
  jnz 1b
2:ret

# parse_request rdi data, rsi len -> rax total bytes (0 incomplete, -1 malformed). Fills the frame.
parse_request:
  push rbx
  push r12
  push r13
  mov rbx,rdi
  lea r12,[rdi+rsi]      # end
  # find the end of the head
  mov r13,rdi
  movdqa xmm1,[rip+x_cr]
1:lea rax,[r13+16]
  cmp rax,r12
  ja 3f
  movdqu xmm0,[r13]
  pcmpeqb xmm0,xmm1
  pmovmskb eax,xmm0
2:test eax,eax
  jz 5f
  bsf ecx,eax
  btr eax,ecx
  lea rdx,[r13+rcx]
  lea rsi,[rdx+4]
  cmp rsi,r12
  ja 6f
  cmp dword ptr [rdx],0x0a0d0a0d
  je .Lhead
  jmp 2b
5:add r13,16
  jmp 1b
3:# tail, byte by byte
  lea rax,[r13+4]
  cmp rax,r12
  ja 6f
  cmp dword ptr [r13],0x0a0d0a0d
  mov rdx,r13
  je .Lhead
  inc r13
  jmp 3b
6:mov rax,r12
  sub rax,rbx
  cmp rax,65536
  ja .Lmal
  xor eax,eax
  jmp .Lpend
.Lhead:
  mov r13,rdx            # at the final CRLFCRLF
  xor eax,eax
  mov [r14+R_AUTH],rax
  mov [r14+R_AUTHLEN],rax
  mov [r14+R_CLOSE],rax
  mov [r14+R_GZ],rax
  mov [r14+R_BODYLEN],rax
  mov [r14+R_QUERY],rax
  mov [r14+R_QLEN],rax
  # method
  mov eax,[rbx]
  mov ecx,M_GET
  cmp eax,0x20544547
  je 7f
  mov ecx,M_POST
  cmp eax,0x54534f50
  je 7f
  mov ecx,M_PUT
  cmp eax,0x20545550
  je 7f
  mov ecx,M_DEL
  cmp eax,0x454c4544
  je 7f
  xor ecx,ecx
7:mov [r14+R_METHOD],rcx
  # target
  mov rdi,rbx
8:cmp rdi,r13
  jae .Lmal
  cmp byte ptr [rdi],' '
  je 9f
  inc rdi
  jmp 8b
9:inc rdi
  mov [r14+R_PATH],rdi
  mov rsi,rdi
10:cmp rsi,r13
  jae .Lmal
  mov al,[rsi]
  cmp al,' '
  je 11f
  cmp al,'?'
  je 12f
  inc rsi
  jmp 10b
12:mov rax,rsi
  sub rax,rdi
  mov [r14+R_PATHLEN],rax
  inc rsi
  mov [r14+R_QUERY],rsi
  mov rdi,rsi
13:cmp rsi,r13
  jae .Lmal
  cmp byte ptr [rsi],' '
  je 14f
  inc rsi
  jmp 13b
14:mov rax,rsi
  sub rax,rdi
  mov [r14+R_QLEN],rax
  jmp 15f
11:mov rax,rsi
  sub rax,rdi
  mov [r14+R_PATHLEN],rax
15:# version: only 1.0 disables keep-alive by default
  # headers, one per line
  mov rdi,rsi
16:cmp rdi,r13
  jae .Lhdone
  cmp byte ptr [rdi],10
  je 17f
  inc rdi
  jmp 16b
17:inc rdi              # at a header line
  mov r8,rdi
  xor r9d,r9d            # content-length seen below
  # dispatch on the first letter, lowercased
  movzx eax,byte ptr [rdi]
  or al,0x20
  cmp al,'a'
  je .Lh_auth
  cmp al,'c'
  je .Lh_c
  jmp 16b
.Lh_auth:
  mov rdi,r8
  lea rsi,[rip+h_auth]
  mov ecx,14
  call ieq
  mov rdi,r8
  jne .Lh_ae
  lea rdi,[r8+14]
  call hdr_value
  mov [r14+R_AUTH],rax
  mov [r14+R_AUTHLEN],rdx
  jmp 16b
.Lh_ae:
  lea rsi,[rip+h_ae]
  mov ecx,16
  call ieq
  mov rdi,r8
  jne 16b
  lea rdi,[r8+16]
  call hdr_value
  mov rdi,r8
  # the value lists "gzip" somewhere
41:cmp rdx,4
  jb 16b
  cmp dword ptr [rax],0x70697a67
  je 42f
  inc rax
  dec rdx
  jmp 41b
42:mov qword ptr [r14+R_GZ],1
  jmp 16b
.Lh_c:
  mov rdi,r8
  lea rsi,[rip+h_cl]
  mov ecx,15
  call ieq
  mov rdi,r8
  jne .Lh_conn
  lea rdi,[r8+15]
  call hdr_value
  mov rdi,rax
  mov rsi,rdx
  push r8
  call parse_u64
  pop r8
  test rdx,rdx
  jz .Lmal
  cmp rax,MAX_BODY
  ja .Lmal
  mov [r14+R_BODYLEN],rax
  mov rdi,r8
  jmp 16b
.Lh_conn:
  lea rsi,[rip+h_conn]
  mov ecx,11
  call ieq
  mov rdi,r8
  jne 16b
  lea rdi,[r8+11]
  call hdr_value
  cmp rdx,5
  jne 18f
  mov rdi,rax
  lea rsi,[rip+v_close]
  mov ecx,5
  call ieq
  jne 18f
  mov qword ptr [r14+R_CLOSE],1
18:mov rdi,r8
  jmp 16b
.Lhdone:
  jmp .Lhd2
.Lmal:
  mov rax,-1
.Lpend:
  pop r13
  pop r12
  pop rbx
  ret
.Lhd2:
  lea rdx,[r13+4]        # body start
  mov [r14+R_BODY],rdx
  mov rax,[r14+R_BODYLEN]
  lea rcx,[rdx+rax]
  cmp rcx,r12
  ja 6f
  mov rax,rcx
  sub rax,rbx
  jmp .Lpend
6:xor eax,eax
  jmp .Lpend
.section .rodata
h_auth: .ascii "authorization:"
h_ae:   .ascii "accept-encoding:"
h_cl:   .ascii "content-length:"
h_conn: .ascii "connection:"
v_close:.ascii "close"
.text
# hdr_value rdi at the value -> rax start, rdx length (spaces and CRLF trimmed). Preserves r8.
hdr_value:
1:cmp byte ptr [rdi],' '
  jne 2f
  inc rdi
  jmp 1b
2:mov rax,rdi
3:mov cl,[rdi]
  cmp cl,13
  je 4f
  cmp cl,10
  je 4f
  inc rdi
  jmp 3b
4:mov rdx,rdi
  sub rdx,rax
5:test rdx,rdx
  jz 6f
  cmp byte ptr [rax+rdx-1],' '
  jne 6f
  dec rdx
  jmp 5b
6:ret

# ---- replies without a job
# reply_err esi status: rbx conn, r12 fd
.globl reply_err
reply_err:
  push r12
  sub rsp,512
  mov rdi,rsp
  mov edx,39
  call http_head
  LIT "{\"errors\":{\"body\":[\"invalid request\"]}}"
  mov rdx,rdi
  sub rdx,rsp
  mov rsi,rsp
  mov rdi,[r14+R_FD]
  call conn_send
  add rsp,512
  pop r12
  ret

# ---- routing. rbx conn, r12 fd stay valid; r13/rbp hold the parse cursor and are saved by route.
# seg_is n, "lit": ZF when segment n equals lit
.macro SEG_IS n,s
  .pushsection .rodata
  773: .ascii "\s"
  774:
  .popsection
  lea rdi,[r14+R_SEGS+\n*16]
  lea rsi,[rip+773b]
  mov ecx,offset 774b-773b
  call seg_eq
.endm
seg_eq:
  cmp rcx,[rdi+8]
  jne 2f
  mov rdi,[rdi]
  test rcx,rcx
  jz 2f
1:mov al,[rdi]
  cmp al,[rsi]
  jne 2f
  inc rdi
  inc rsi
  dec rcx
  jnz 1b
2:ret

# auth: edi 1 required / 0 optional -> CF set when the request was refused (401 already sent)
auth:
  xor eax,eax
  mov [r14+R_VIEWER],rax
  mov [r14+R_TOK],rax
  mov [r14+R_TOKLEN],rax
  mov rsi,[r14+R_AUTH]
  test rsi,rsi
  jnz 1f
  test edi,edi
  jnz .Lref
  clc
  ret
1:mov rdx,[r14+R_AUTHLEN]
  cmp rdx,6
  jb .Lref
  mov eax,[rsi]
  cmp eax,0x656b6f54
  jne .Lref
  cmp word ptr [rsi+4],0x206e
  jne .Lref
  lea rdi,[rsi+6]
  lea rsi,[rdx-6]
  mov [r14+R_TOK],rdi
  mov [r14+R_TOKLEN],rsi
  mov rdx,[r15+W_NOW_S]
  call jwt_verify
  test rax,rax
  jz .Lref
  mov [r14+R_VIEWER],rax
  clc
  ret
.Lref:
  mov esi,401
  call reply_err
  stc
  ret

# job_new -> rax job with routing fields set; string cursor in R_CUR.
job_new:
  mov rax,[r14+R_TOTAL]
  shl rax,2
  lea rdi,[rax+J_SIZE+512]
  call alloc
  push rax
  mov rdi,rax
  mov ecx,J_SIZE
  xor eax,eax
  rep stosb
  mov rax,[rsp]
  lea rcx,[rax+J_SIZE]
  mov [r14+R_CUR],rcx
  mov rcx,[r15+W_ID]
  mov [rax+J_WID],ecx
  mov [rax+J_FD],r12d
  mov ecx,[rbx+C_GEN]
  mov [rax+J_GEN],ecx
  mov rcx,[r14+R_VIEWER]
  mov [rax+J_VIEWER],rcx
  mov rcx,[r15+W_NOW_MS]
  mov [rax+J_T0],rcx
  mov dword ptr [rax+J_STATUS],200
  mov rcx,[r14+R_GZ]
  mov [rax+J_GZ],ecx
  pop rax
  ret

# keep_token rax job: the presented token is echoed back, so copy it
keep_token:
  mov rdi,[r14+R_CUR]
  mov [rax+J_TOK],rdi
  mov rcx,[r14+R_TOKLEN]
  mov [rax+J_TOK+8],rcx
  mov rsi,[r14+R_TOK]
  push rax
  call mcpy
  pop rax
  mov [r14+R_CUR],rdi
  ret

# put_seg rax job, rcx slot offset, edx segment index: percent-decoded copy, NUL-terminated
put_seg:
  shl rdx,4
  mov rsi,[r14+R_SEGS+rdx]
  mov rdx,[r14+R_SEGS+rdx+8]
# put_pct rax job, rcx slot offset, rsi src, rdx len (decodes %xx; '+' stays)
put_pct:
  mov rdi,[r14+R_CUR]
  mov [rax+rcx],rdi
  push rax
  push rcx
  push rdi
  xor r8d,r8d            # plus-as-space flag off
  call pct_copy
  mov byte ptr [rdi],0
  lea rax,[rdi+1]
  mov [r14+R_CUR],rax
  pop rdx
  sub rdi,rdx
  pop rcx
  pop rax
  mov [rax+rcx+8],rdi
  ret
# pct_copy rdi dst, rsi src, rdx len, r8d 1: '+' means space
pct_copy:
  test rdx,rdx
  jz 9f
1:movzx eax,byte ptr [rsi]
  cmp al,'%'
  jne 3f
  cmp rdx,3
  jb 3f
  movzx ecx,byte ptr [rsi+1]
  call hexv
  js 3f
  mov r9d,ecx
  movzx ecx,byte ptr [rsi+2]
  call hexv
  js 3f
  shl r9d,4
  or ecx,r9d
  mov [rdi],cl
  inc rdi
  add rsi,3
  sub rdx,3
  jnz 1b
  ret
3:cmp al,'+'
  jne 4f
  test r8d,r8d
  jz 4f
  mov al,' '
4:mov [rdi],al
  inc rdi
  inc rsi
  dec rdx
  jnz 1b
9:ret
hexv:                 # ecx char -> ecx value, SF set when not hex
  cmp cl,'9'
  ja 1f
  sub ecx,'0'
  ret
1:or cl,0x20
  sub ecx,'a'
  js 2f
  cmp ecx,5
  ja 3f
  add ecx,10
  test ecx,ecx
2:ret
3:mov ecx,-1
  test ecx,ecx
  ret

# query_get rdi key, rsi keylen -> rax raw value ptr (0 absent), rdx len
query_get:
  push rbx
  push r12
  mov rbx,[r14+R_QUERY]
  mov r12,[r14+R_QLEN]
  test rbx,rbx
  jz 8f
  add r12,rbx            # end
1:cmp rbx,r12
  jae 8f
  # this pair: rbx..r8 (ends at & or end), key part up to =
  mov r8,rbx
2:cmp r8,r12
  jae 3f
  cmp byte ptr [r8],'&'
  je 3f
  inc r8
  jmp 2b
3:mov r9,rbx
4:cmp r9,r8
  jae 5f
  cmp byte ptr [r9],'='
  je 5f
  inc r9
  jmp 4b
5:mov rax,r9
  sub rax,rbx
  cmp rax,rsi
  jne 7f
  xor ecx,ecx
6:cmp rcx,rsi
  je 65f
  mov al,[rbx+rcx]
  cmp al,[rdi+rcx]
  jne 7f
  inc rcx
  jmp 6b
65:lea rax,[r9+1]
  mov rdx,r8
  sub rdx,rax
  cmp r9,r8
  jne 66f
  mov rax,r9
  xor edx,edx
66:pop r12
  pop rbx
  ret
7:lea rbx,[r8+1]
  jmp 1b
8:xor eax,eax
  xor edx,edx
  pop r12
  pop rbx
  ret

.section .rodata
q_limit: .ascii "limit"
q_offset:.ascii "offset"
q_tag: .ascii "tag"
q_author: .ascii "author"
q_fav: .ascii "favorited"
.text
# query_page -> rax limit, rdx offset; CF when out of range
query_page:
  push rbx
  lea rdi,[rip+q_limit]
  mov esi,5
  call query_get
  mov ebx,20
  test rax,rax
  jz 1f
  mov rdi,rax
  mov rsi,rdx
  call parse_u64
  test rdx,rdx
  jz 8f
  mov rbx,rax
  test rbx,rbx
  jz 8f
  cmp rbx,100
  ja 8f
1:lea rdi,[rip+q_offset]
  mov esi,6
  call query_get
  xor ecx,ecx
  test rax,rax
  jz 2f
  mov rdi,rax
  mov rsi,rdx
  call parse_u64
  test rdx,rdx
  jz 8f
  mov ecx,0x7fffffff
  cmp rax,rcx
  ja 8f
  mov rcx,rax
2:mov rax,rbx
  mov rdx,rcx
  pop rbx
  clc
  ret
8:pop rbx
  stc
  ret

# ---- JSON bodies
# body_open edx wrapper key -> CF when the body or the wrapper is not usable. Sets R_OBJ..R_OBJEND.
body_open:
  push rdx
  push rcx
  mov rdi,[r14+R_BODY]
  mov rsi,[r14+R_BODYLEN]
  add rsi,rdi
  call json_valid
  pop rcx
  pop rdx
  test rax,rax
  jz 9f
  mov rdi,[r14+R_BODY]
  mov rsi,[r14+R_BODYLEN]
  add rsi,rdi
  call json_field
  test rax,rax
  jz 9f
  cmp byte ptr [rax],'{'
  jne 9f
  mov [r14+R_OBJ],rax
  mov [r14+R_OBJEND],rdx
  clc
  ret
9:stc
  ret

# body_str rax job, rcx slot, rdx key, rsi keylen, edi flags -> rax job, CF on a bad field.
# The slot stays 0 when the field is absent or null.
body_str:
  push rbx
  push r12
  push r13
  mov rbx,rax
  mov r12,rcx
  mov r13d,edi
  mov rcx,rsi
  mov rdi,[r14+R_OBJ]
  mov rsi,[r14+R_OBJEND]
  call json_field
  test rax,rax
  jz .Lbs_abs
  cmp byte ptr [rax],'n'
  je .Lbs_abs
  cmp byte ptr [rax],'"'
  jne .Lbs_bad
  lea rsi,[rax+1]
  dec rdx
  mov rdi,[r14+R_CUR]
  mov [rbx+r12],rdi
  push rdi
  call json_unescape
  pop rdx
  test eax,eax
  jz .Lbs_bad
  mov byte ptr [rdi],0
  lea rax,[rdi+1]
  mov [r14+R_CUR],rax
  sub rdi,rdx
  mov [rbx+r12+8],rdi
  test r13d,F_NONEMPTY
  jz .Lbs_ok
  test rdi,rdi
  jz .Lbs_bad
.Lbs_ok:
  mov rax,rbx
  pop r13
  pop r12
  pop rbx
  clc
  ret
.Lbs_abs:
  test r13d,F_REQ
  jz .Lbs_ok
.Lbs_bad:
  mov rax,rbx
  pop r13
  pop r12
  pop rbx
  stc
  ret
.macro BSTR slot,key,flags
  .pushsection .rodata
  775: .ascii "\key"
  776:
  .popsection
  mov rcx,\slot
  lea rdx,[rip+775b]
  mov esi,offset 776b-775b
  mov edi,\flags
  call body_str
  jc route_422_job
.endm
.macro OPEN key
  .pushsection .rodata
  777: .ascii "\key"
  778:
  .popsection
  lea rdx,[rip+777b]
  mov ecx,offset 778b-777b
  call body_open
.endm

# ---- the router. rbx conn, r12 fd.
route:
  push r13
  push rbp
  # split /api/...
  mov rdi,[r14+R_PATH]
  mov rcx,[r14+R_PATHLEN]
  cmp rcx,5
  jb route_404
  mov eax,[rdi]
  cmp eax,0x6970612f
  jne route_404
  cmp byte ptr [rdi+4],'/'
  jne route_404
  add rdi,5
  sub rcx,5
  xor edx,edx            # segment index
  lea rsi,[rdi+rcx]      # end
1:cmp edx,5
  jae route_404
  mov r8,rdi
2:cmp rdi,rsi
  jae 3f
  cmp byte ptr [rdi],'/'
  je 3f
  inc rdi
  jmp 2b
3:mov rax,rdx
  shl rax,4
  mov [r14+R_SEGS+rax],r8
  mov rcx,rdi
  sub rcx,r8
  mov [r14+R_SEGS+rax+8],rcx
  inc edx
  cmp rdi,rsi
  jae 4f
  inc rdi
  jmp 1b
4:mov [r14+R_NSEGS],rdx
  SEG_IS 0,tags
  je r_tags_
  SEG_IS 0,articles
  je r_articles
  SEG_IS 0,user
  je r_user_
  SEG_IS 0,users
  je r_users
  SEG_IS 0,profiles
  je r_profiles
route_404:
  mov esi,404
route_err:
  call reply_err
route_ret:
  pop rbp
  pop r13
  ret
route_422:
  mov esi,422
  jmp route_err
route_422_job:
  mov rdi,rax
  call free
  jmp route_422

# submit rax job, ecx kind
submit:
  mov [rax+J_KIND],ecx
  mov dword ptr [rbx+C_BUSY],1
  mov rdi,rax
  call enqueue
  pop rax                # our return address: tail out of the router
  jmp route_ret

r_tags_:
  cmp qword ptr [r14+R_METHOD],M_GET
  jne route_404
  cmp qword ptr [r14+R_NSEGS],1
  jne route_404
  xor eax,eax
  mov [r14+R_VIEWER],rax
  call job_new
  mov ecx,K_TAGS
  call submit

r_user_:
  cmp qword ptr [r14+R_NSEGS],1
  jne route_404
  mov edi,1
  call auth
  jc route_ret
  cmp qword ptr [r14+R_METHOD],M_GET
  jne 1f
  call job_new
  call keep_token
  mov ecx,K_USER
  call submit
1:cmp qword ptr [r14+R_METHOD],M_PUT
  jne route_404
  OPEN user
  jc route_422
  call job_new
  call keep_token
  BSTR J_EMAIL,email,F_NONEMPTY
  BSTR J_USERNAME,username,F_NONEMPTY
  BSTR J_PASSWORD,password,F_NONEMPTY
  BSTR J_BIO,bio,0
  BSTR J_IMAGE,image,0
  cmp qword ptr [rax+J_PASSWORD+8],72
  ja route_422_job
  mov ecx,K_UPDUSER
  cmp qword ptr [rax+J_PASSWORD],0
  je 2f
  mov dword ptr [rax+J_SUB],K_UPDUSER
  mov ecx,K_BC_HASH
2:call submit

r_users:
  cmp qword ptr [r14+R_METHOD],M_POST
  jne route_404
  xor eax,eax
  mov [r14+R_VIEWER],rax
  cmp qword ptr [r14+R_NSEGS],1
  je .Lreg
  cmp qword ptr [r14+R_NSEGS],2
  jne route_404
  SEG_IS 1,login
  jne route_404
  OPEN user
  jc route_422
  call job_new
  BSTR J_EMAIL,email,F_REQ|F_NONEMPTY
  BSTR J_PASSWORD,password,F_REQ|F_NONEMPTY
  mov ecx,K_LOGIN
  call submit
.Lreg:
  OPEN user
  jc route_422
  call job_new
  BSTR J_USERNAME,username,F_REQ|F_NONEMPTY
  BSTR J_EMAIL,email,F_REQ|F_NONEMPTY
  BSTR J_PASSWORD,password,F_REQ|F_NONEMPTY
  cmp qword ptr [rax+J_PASSWORD+8],72
  ja route_422_job
  mov dword ptr [rax+J_SUB],K_REG
  mov dword ptr [rax+J_STATUS],201
  mov ecx,K_BC_HASH
  call submit

r_profiles:
  mov rax,[r14+R_NSEGS]
  cmp rax,2
  je .Lprof_get
  cmp rax,3
  jne route_404
  SEG_IS 2,follow
  jne route_404
  mov edi,1
  call auth
  jc route_ret
  mov r13d,K_FOLLOW
  cmp qword ptr [r14+R_METHOD],M_POST
  je 1f
  mov r13d,K_UNFOLLOW
  cmp qword ptr [r14+R_METHOD],M_DEL
  jne route_404
1:call job_new
  mov ecx,J_USERNAME
  mov edx,1
  call put_seg
  mov ecx,r13d
  call submit
.Lprof_get:
  cmp qword ptr [r14+R_METHOD],M_GET
  jne route_404
  xor edi,edi
  call auth
  jc route_ret
  call job_new
  mov ecx,J_USERNAME
  mov edx,1
  call put_seg
  mov ecx,K_PROFILE
  call submit

r_articles:
  mov rax,[r14+R_NSEGS]
  cmp rax,1
  je .Lart_root
  SEG_IS 1,feed
  jne .Lart_slug
  cmp qword ptr [r14+R_NSEGS],2
  jne .Lart_slug
  cmp qword ptr [r14+R_METHOD],M_GET
  jne .Lart_slug
  mov edi,1
  call auth
  jc route_ret
  call query_page
  jc route_422
  mov r13,rax
  mov rbp,rdx
  call job_new
  mov [rax+J_A],r13
  mov [rax+J_B],rbp
  mov ecx,K_FEED
  call submit
.Lart_root:
  cmp qword ptr [r14+R_METHOD],M_GET
  je .Lart_list
  cmp qword ptr [r14+R_METHOD],M_POST
  jne route_404
  mov edi,1
  call auth
  jc route_ret
  OPEN article
  jc route_422
  call job_new
  BSTR J_TITLE,title,F_REQ|F_NONEMPTY
  BSTR J_DESC,description,F_REQ|F_NONEMPTY
  BSTR J_BODY,body,F_REQ|F_NONEMPTY
  mov dword ptr [rax+J_STATUS],201
  call tag_list
  jc route_422_job
  mov ecx,K_ARTNEW
  call submit
.Lart_list:
  xor edi,edi
  call auth
  jc route_ret
  call query_page
  jc route_422
  mov r13,rax
  mov rbp,rdx
  call job_new
  mov [rax+J_A],r13
  mov [rax+J_B],rbp
  # the first filter given applies: tag, author, favorited
  mov r13,rax
  lea rdi,[rip+q_tag]
  mov esi,3
  mov ebp,SUB_TAG
  call query_get
  test rdx,rdx
  jnz 2f
  lea rdi,[rip+q_author]
  mov esi,6
  mov ebp,SUB_AUTHOR
  call query_get
  test rdx,rdx
  jnz 2f
  lea rdi,[rip+q_fav]
  mov esi,9
  mov ebp,SUB_FAVORITED
  call query_get
  test rdx,rdx
  jnz 2f
  mov rax,r13
  mov ecx,K_LIST
  call submit
2:# decoded with '+' as a space
  mov rsi,rax
  mov rdi,[r14+R_CUR]
  mov [r13+J_KEY],rdi
  push rdi
  mov r8d,1
  call pct_copy
  pop rax
  mov rcx,rdi
  sub rcx,rax
  mov [r13+J_KEY+8],rcx
  mov byte ptr [rdi],0
  inc rdi
  mov [r14+R_CUR],rdi
  mov [r13+J_SUB],ebp
  mov rax,r13
  mov ecx,K_LIST
  call submit

.Lart_slug:
  mov rax,[r14+R_NSEGS]
  cmp rax,2
  je .Lart_one
  cmp rax,3
  jb route_404
  SEG_IS 2,favorite
  jne .Lart_cm
  cmp qword ptr [r14+R_NSEGS],3
  jne route_404
  mov edi,1
  call auth
  jc route_ret
  mov r13d,K_FAV
  cmp qword ptr [r14+R_METHOD],M_POST
  je 1f
  mov r13d,K_UNFAV
  cmp qword ptr [r14+R_METHOD],M_DEL
  jne route_404
1:call job_new
  mov ecx,J_KEY
  mov edx,1
  call put_seg
  mov ecx,r13d
  call submit
.Lart_cm:
  SEG_IS 2,comments
  jne route_404
  cmp qword ptr [r14+R_NSEGS],4
  je .Lcm_del
  cmp qword ptr [r14+R_METHOD],M_GET
  jne .Lcm_new
  xor edi,edi
  call auth
  jc route_ret
  call job_new
  mov ecx,J_KEY
  mov edx,1
  call put_seg
  mov ecx,K_COMMENTS
  call submit
.Lcm_new:
  cmp qword ptr [r14+R_METHOD],M_POST
  jne route_404
  mov edi,1
  call auth
  jc route_ret
  OPEN comment
  jc route_422
  call job_new
  mov ecx,J_KEY
  mov edx,1
  call put_seg
  BSTR J_S1,body,F_REQ|F_NONEMPTY
  mov ecx,K_CMTNEW
  call submit
.Lcm_del:
  cmp qword ptr [r14+R_METHOD],M_DEL
  jne route_404
  mov edi,1
  call auth
  jc route_ret
  mov rdi,[r14+R_SEGS+3*16]
  mov rsi,[r14+R_SEGS+3*16+8]
  call parse_u64
  test rdx,rdx
  jz route_404
  mov r13,rax
  call job_new
  mov [rax+J_A],r13
  mov ecx,J_KEY
  mov edx,1
  call put_seg
  mov ecx,K_CMTDEL
  call submit
.Lart_one:
  mov rax,[r14+R_METHOD]
  cmp rax,M_GET
  je .Lone_get
  cmp rax,M_PUT
  je .Lone_put
  cmp rax,M_DEL
  jne route_404
  mov edi,1
  call auth
  jc route_ret
  call job_new
  mov ecx,J_KEY
  mov edx,1
  call put_seg
  mov ecx,K_ARTDEL
  call submit
.Lone_get:
  xor edi,edi
  call auth
  jc route_ret
  call job_new
  mov qword ptr [rax+J_A],1
  mov dword ptr [rax+J_SUB],SUB_SLUG
  mov ecx,J_KEY
  mov edx,1
  call put_seg
  mov ecx,K_LIST
  call submit
.Lone_put:
  mov edi,1
  call auth
  jc route_ret
  OPEN article
  jc route_422
  call job_new
  mov ecx,J_KEY
  mov edx,1
  call put_seg
  BSTR J_TITLE,title,F_NONEMPTY
  BSTR J_DESC,description,F_NONEMPTY
  BSTR J_BODY,body,F_NONEMPTY
  mov ecx,K_ARTUPD
  call submit

# tag_list rax job -> rax job; CF on a bad tagList. Builds the text[] literal in J_TAGS.
tag_list:
  push rbx
  push r12
  push r13
  push rbp
  mov rbx,rax
  mov rdi,[r14+R_OBJ]
  mov rsi,[r14+R_OBJEND]
  lea rdx,[rip+k_tl]
  mov ecx,7
  call json_field
  test rax,rax
  jz .Ltl_ok
  cmp byte ptr [rax],'n'
  je .Ltl_ok
  cmp byte ptr [rax],'['
  jne .Ltl_bad
  mov r12,rax
  inc r12                # element cursor
  mov r13,rdx            # end of the array
  mov rbp,[r14+R_CUR]    # output
  lea rax,[rbp+1]
  mov byte ptr [rbp],'{'
  mov rbp,rax
  xor ecx,ecx            # elements so far
  push rcx
.Ltl_next:
  mov rdi,r12
  mov rsi,r13
  call skip_ws
  mov r12,rdi
  cmp byte ptr [r12],']'
  je .Ltl_end
  cmp byte ptr [r12],','
  jne 1f
  inc r12
  jmp .Ltl_next
1:cmp byte ptr [r12],'"'
  jne .Ltl_bad2
  mov rdi,r12
  mov rsi,r13
  xor edx,edx
  call skip_value
  jc .Ltl_bad2
  # decode the element past the output's maximum extent, then escape it into place
  lea rsi,[r12+1]
  lea rdx,[rdi-1]
  mov r12,rdi
  mov rdi,[r14+R_TOTAL]
  lea rdi,[rbp+rdi*2]
  add rdi,64
  push rdi
  call json_unescape
  pop rsi
  test eax,eax
  jz .Ltl_bad2
  mov rcx,rdi
  sub rcx,rsi
  jz .Ltl_bad2           # empty tag
  mov rax,[rsp]
  test rax,rax
  jz 2f
  mov byte ptr [rbp],','
  inc rbp
2:inc qword ptr [rsp]
  mov rdi,rbp
  mov byte ptr [rdi],'"'
  inc rdi
3:mov al,[rsi]
  inc rsi
  cmp al,'"'
  je 4f
  cmp al,0x5c
  jne 5f
4:mov byte ptr [rdi],0x5c
  inc rdi
5:mov [rdi],al
  inc rdi
  dec rcx
  jnz 3b
  mov byte ptr [rdi],'"'
  lea rbp,[rdi+1]
  jmp .Ltl_next
.Ltl_end:
  pop rax
  test rax,rax
  jz .Ltl_ok             # empty array: same as no tags
  mov byte ptr [rbp],'}'
  inc rbp
  mov rdi,[r14+R_CUR]
  mov [rbx+J_TAGS],rdi
  mov rax,rbp
  sub rax,rdi
  mov [rbx+J_TAGS+8],rax
  mov byte ptr [rbp],0
  inc rbp
  mov [r14+R_CUR],rbp
.Ltl_ok:
  mov rax,rbx
  pop rbp
  pop r13
  pop r12
  pop rbx
  clc
  ret
.Ltl_bad2:
  add rsp,8
.Ltl_bad:
  mov rax,rbx
  pop rbp
  pop r13
  pop r12
  pop rbx
  stc
  ret
.section .rodata
k_tl: .ascii "tagList"
