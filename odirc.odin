package odirc

import "core:fmt"
import "core:net"
import "core:terminal/ansi"
import "core:bytes"
import "core:strings"

//if this weren't a toy, probably get this from args or something
server_adress :: "irc.libera.chat:6667"
nickname :: "dudv2s-toy-client"

printout_raw_received :: false
printout_msg_received :: true

RED   :: ansi.CSI + ansi.FG_RED    + ansi.SGR
GREEN :: ansi.CSI + ansi.FG_GREEN  + ansi.SGR
YELLOW:: ansi.CSI + ansi.FG_YELLOW + ansi.SGR
RESET :: ansi.CSI + ansi.RESET     + ansi.SGR

STR_ERR :: RED + "[error]" + RESET
STR_OK  :: GREEN + "[ok]" + RESET
STR_DBG :: YELLOW + "[dbg]" + RESET

EOL : string : "\r\n"
EOL_B :: []u8{'\r', '\n'}

data :: struct{
    endpoint: net.Endpoint,
    socket: net.TCP_Socket,

    /*
    https://modern.ircdocs.horse/#client-to-server-protocol-structure
    Most IRC servers limit messages to 512 bytes in length, including the
    trailing CR-LF characters. Implementations which include message tags need
    to allow additional bytes for the tags section of a message; clients must
    allow 8191 additional bytes and servers must allow 4096 additional bytes.
    */
    buf_recv: [512 + 8191 + 100 /* some leniency */]u8,
    buf_send: [512 + 4096]u8,
    current_send_len: int,
    recv_buf_filled: int,
    recv_buf_search_cursor: int,
    message : string,
    eol_idx : int
}

//Using a single buffer to construct messages, rather than doing
//a bunch of stupid string allocations and concatenations.

send_buf_append :: proc(data:^data, vars: ..any){
    using data
    str := fmt.bprint(
        buf = buf_send[current_send_len:],
        sep = "", //do not add spaces between items
        args = vars)
    current_send_len += len(str)
}
send_buf_appendl :: proc(data:^data, vars: ..any){
    send_buf_append(data, ..vars)
    send_buf_append(data, EOL)
}

send_buffer :: proc(data:^data) -> bool {
    using data
    defer current_send_len = 0
    {
        //debug: print what we're sending
        msg := string(buf_send[0:current_send_len])
        fmt.printf(">>> '%q'\n", msg)
    }
    sent, err := net.send_tcp(socket, buf_send[0:current_send_len])
    if err != nil {
        msg := string(buf_send[0:current_send_len])
        fmt.printf("%v failed to send '%q': '%v'. Sent %d bytes\n",
            STR_ERR, msg, err, sent)
        return false
    }
    return true
}

main :: proc(){
    fmt.println("oh dear, looks like you've run an odd irc client")
    defer fmt.println("good yard, and fair tea.")

    assert(len(EOL) == len(EOL_B))

    data: data
    using data

    //resolve host-name to an endpoint (IP:PORT)
    {
        fmt.printf("resolving server address '%s'... ", server_adress)
        err: net.Network_Error
        endpoint, err = net.resolve_ip4(server_adress)
        if err != nil {
            fmt.println(STR_ERR, err)
            return
        }
        //I can't believe its not DNS!!
        fmt.println(STR_OK, "got endpoint:", endpoint)
    }

    // open up a socket
    {
        fmt.printf("dialing server... ")
        err: net.Network_Error
        //Poor server, it has no idea what it's in for
        socket, err = net.dial_tcp(endpoint)
        if err != nil {
            fmt.println(STR_ERR, err)
            return
        }
        fmt.println(STR_OK, "connected to server")
    }
    //defer runs at the end of the scope
    //can't be within the scope above)
    defer{
        net.close(socket)
        fmt.println("disconnected from server")
    }

    //TODO: apologise to the server for being a terrible client

    //Tentatively say hello
    {
        send_buf_appendl(&data, "NICK ", nickname)
        send_buf_appendl(&data, "USER ", nickname, " 0 * :", nickname)
        send_buf_appendl(&data, "JOIN #odin-lang")
        send_buf_appendl(&data, "PRIVMSG #odin-lang :hellope, ping response test")
        fmt.printf("sending greetings... ")
        send_buffer(&data)
    }

    for{
        receive_tcp(&data) or_break
        for{
            //There might be multiple messages received.
            find_next_message(&data) or_break
            read_message(&data)
        }
    }
}

receive_tcp :: proc(data:^data) -> bool {
    using data
    if recv_buf_search_cursor == recv_buf_filled{
        recv_buf_filled = 0
    }
    if recv_buf_filled != 0
    {
        //handle any leftover start of message in the buf_recv
        fmt.print(STR_DBG)
        fmt.printfln(" moving buffer: EOL %v, Cursor: %v", eol_idx, recv_buf_filled);
        m_end := eol_idx + len(EOL)
        copy(buf_recv[:], buf_recv[m_end:recv_buf_filled])
        recv_buf_filled -= m_end
    }
    recv_buf_search_cursor = recv_buf_filled
    assert(recv_buf_search_cursor != len(buf_recv))
    count, err := net.recv_tcp(socket, buf_recv[recv_buf_filled:])
    recv_buf_filled += count
    assert(recv_buf_filled <= len(buf_recv))
    if err != nil {
        fmt.println(STR_ERR, "failed to receive:", err)
        return false
    }
    if count == 0 {
        fmt.println("server closed connection")
        return false
    }else{
        assert(recv_buf_filled != 0)
    }
    if(printout_raw_received){
        msg := string(data.buf_recv[recv_buf_search_cursor:recv_buf_filled])
        fmt.printf("<<< %q\n", msg)
    }
    return true
}

find_next_message :: proc (data:^data) -> bool {
    using data
    assert(len(EOL_B) == 2)
    // :: might be split over 2 receive calls.
    search := max(0, recv_buf_search_cursor - 1)

    eol_idx = bytes.index(buf_recv[search:recv_buf_filled], EOL_B)
    if eol_idx == -1{
        //It ain't here
        if(recv_buf_filled == len(buf_recv)){
            //buffer full of junk, drop it.
            fmt.println(STR_ERR + "Could not find EOL, buffer discarded")
            recv_buf_filled = 0
        }
        recv_buf_search_cursor = recv_buf_filled
        return false
    }
    eol_idx += search
    message = string(buf_recv[recv_buf_search_cursor:eol_idx])
    recv_buf_search_cursor = eol_idx + len(EOL)

    if(printout_msg_received){
        fmt.println("<<< ", message)
    }
    return true
}

read_message :: proc(data:^data){
    using data
    command, params, prefix : string

    if len(message) == 0 {
        return
    }

    space := strings.index(message, " ")
    if space == -1 {
        command = message
    }
    else{
        if message[0] == ':' {
            prefix = message[:space]
            message = message[space + 1:]
        }
        space = strings.index(message, " ")
        if space == -1{
            command = message
        }
        else{
            command = message[:space]
            params = message[space + 1:]
        }
    }
    switch command{
        case "PING":{
            send_buf_appendl(data, "PONG ", params)
            send_buffer(data)
        }
    }
}
    /*
'<<< '":dudv2!~dudv2@user/DudV2 PRIVMSG #odin-lang :hazzah\r\n"'
<<< '":dudv2!~dudv2@user/DudV2 PRIVMSG #odin-lang :not bad for sunday\r\n"'
<<< '"PING :osmium.libera.chat\r\n"'
     */
