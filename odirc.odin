package odirc

import "core:fmt"
import "core:net"
import "core:terminal/ansi"

//if this weren't a toy, probably get this from args or something
server_adress :: "irc.libera.chat:6667"
nickname :: "dudv2s-toy-client"

RED   :: ansi.CSI + ansi.FG_RED    + ansi.SGR
GREEN :: ansi.CSI + ansi.FG_GREEN  + ansi.SGR
RESET :: ansi.CSI + ansi.RESET     + ansi.SGR

STR_ERR :: RED + "[error]" + RESET
STR_OK  :: GREEN + "[ok]" + RESET

EOL :: "\r\n"

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
    current_send_len: int
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

    data: data

    //resolve host-name to an endpoint (IP:PORT)
    {
        fmt.printf("resolving server address '%s'... ", server_adress)
        err: net.Network_Error
        data.endpoint, err = net.resolve_ip4(server_adress)
        if err != nil {
            fmt.println(STR_ERR, err)
            return
        }
        //I can't believe its not DNS!!
        fmt.println(STR_OK, "got endpoint:", data.endpoint)
    }

    // open up a socket
    {
        fmt.printf("dialing server... ")
        err: net.Network_Error
        //Poor server, it has no idea what it's in for
        data.socket, err = net.dial_tcp(data.endpoint)
        if err != nil {
            fmt.println(STR_ERR, err)
            return
        }
        fmt.println(STR_OK, "connected to server")
    }
    //defer runs at the end of the scope
    //can't be within the scope above)
    defer{
        net.close(data.socket)
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

    //Receive loop
    //just print out what we get
    for {
        count, err := net.recv_tcp(data.socket, data.buf_recv[:])
        if err != nil {
            fmt.println(STR_ERR, "failed to receive:", err)
            break
        }
        if count == 0 {
            fmt.println("server closed connection")
            break
        }
        msg := string(data.buf_recv[0:count])
        fmt.printf("<<< '%q'\n", msg)
    }
}

