defmodule Elixium.P2P.Server do
  require IEx
  alias Elixium.P2P.GhostProtocol.Message
  alias Elixium.P2P.PeerStore

  @moduledoc """
    Provides functions for listening + responding to incoming connections from a peer
  """

  @doc """
    Start a server and pass the socket to a listener function
  """
  @spec start(integer) :: none
  def start(port \\ 31_013) do
    IO.puts("Starting server on port #{@port}.")
    {:ok, listen_socket} = :gen_tcp.listen(@port, [:binary, reuseaddr: true, active: false])

    # Spawn 10 processes to handle peer connections
    # This is fine for now, we only ever will have a maximum connection to n
    # nodes at a time. Ranch lib does connection pooling as well and it might
    # be worth implementing in the future, but this should work
    for _ <- 0..10, do: spawn(fn -> authenticate_peer(listen_socket) end)

    Process.sleep(:infinity)
  end

  # Accept an incoming connection from a peer and decide whether
  # they are a new peer or someone we've talked to previously,
  # and then authenticate them accordingly
  @spec authenticate_peer(reference) :: none
  defp authenticate_peer(listen_socket) do
    {:ok, socket} = :gen_tcp.accept(listen_socket)

    peername = get_peername(socket)
    IO.puts("Accepted message from #{peername}")

    handshake = Message.read(socket)

    # If the handshake message contains JUST an identifier, the peer
    # is signaling to us that they've talked to us before. We can try
    # to find them in the database. Otherwise, they should be passing
    # multiple pieces of data in this request, in effort to give us
    # the information we need in order to register them.
    key =
      case handshake do
        %{identifier: i, salt: s, prime: p} -> register_new_peer(handshake, socket)
        %{identifier: identifier} -> authenticate_known_peer(identifier, socket)
      end

    # Truncate the key to be 32 bytes (256 bits) since AES256 won't accept anything bigger
    # Originally, I was worried this would be a security flaw, but according to
    # https://crypto.stackexchange.com/questions/3288/is-truncating-a-hashed-private-key-with-sha-1-safe-to-use-as-the-symmetric-key-f
    # is isn't
    <<session_key::binary-size(32)>> <> rest = key

    IO.puts("Authenticated with peer.")

    peername = get_peername(socket)
    server_handler(socket, session_key, peername)
  end

  # Using the identifier, find the verifier, generator, and prime for a peer we know
  # and then communicate back and forth with them until we've verified them
  @spec authenticate_known_peer(String.t(), reference) :: bitstring
  defp authenticate_known_peer(identifier, socket) do
    {salt, prime, generator, peer_verifier} = PeerStore.load_peer(identifier)

    # Necesarry in order to generate the public value & session key
    server =
      Strap.protocol(:srp6a, prime, generator)
      |> Strap.server(peer_verifier)

    # Our public value. The peer will need this in order to generate the derived
    # session key
    public_value =
      server
      |> Strap.public_value()
      |> Base.encode64()

    challenge =
      Message.build("HANDSHAKE_CHALLENGE", %{
        salt: salt,
        prime: prime,
        generator: generator,
        public_value: public_value
      })

    :ok = :gen_tcp.send(socket, challenge)

    %{public_value: peer_public_value} = Message.read(socket)
    {:ok, peer_public_value} = Base.decode64(peer_public_value)
    {:ok, shared_master_key} = Strap.session_key(server, peer_public_value)

    shared_master_key
  end

  # Handle incoming authentication messages from peers, and save their
  # identity to the database for later
  @spec register_new_peer(map, reference) :: bitstring
  defp register_new_peer(message, socket) do
    %{
      public_value: peer_public_value,
      generator: generator,
      prime: prime,
      verifier: peer_verifier,
      salt: salt,
      identifier: peer_identifier
    } = message

    {:ok, peer_verifier} = Base.decode64(peer_verifier)
    {:ok, peer_public_value} = Base.decode64(peer_public_value)

    server =
      :srp6a
      |> Strap.protocol(prime, generator)
      |> Strap.server(peer_verifier)

    server_public_value =
      server
      |> Strap.public_value()
      |> Base.encode64()

    response = Message.build("HANDSHAKE_AUTH", %{public_value: server_public_value})

    :ok = :gen_tcp.send(socket, response)

    {:ok, shared_master_key} = Strap.session_key(server, peer_public_value)

    # Now that we've successfully authenticated the peer, we save this data for use
    # in future authentications
    PeerStore.register_peer({peer_identifier, salt, prime, generator, peer_verifier})

    shared_master_key
  end

  @spec server_handler(reference, <<_::256>>, String.t()) :: none
  defp server_handler(socket, session_key, peername) do
    message = Message.read(socket, session_key)

    IO.puts("Accepted message from #{peername}")
    # IO.inspect message

    server_handler(socket, session_key, peername)
  end

  @spec get_peername(reference) :: String.t()
  defp get_peername(socket) do
    {:ok, {addr, port}} = :inet.peername(socket)

    addr
    |> :inet_parse.ntoa()
    |> to_string()
  end
end