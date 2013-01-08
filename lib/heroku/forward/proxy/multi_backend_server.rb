module Heroku
  module Forward
    module Proxy

      class MultiBackendServer
        attr_reader :host, :port
        attr_accessor :logger

        def initialize(backends, options = {})
          @host = options[:host] || '0.0.0.0'
          @port = options[:port] || 3000
          @logger = options[:logger]
          @timeout = options[:timeout]
          @backends = backends.map {|b| Backend.new(:backend => b, :logger => @logger, :timeout => @timeout )}
          @rejection_data = options[:rejection_data]
          @delay = options[:delay]
        end

        class Backend
          attr_reader :backend, :dead
          attr_accessor :logger, :load

          def initialize(options = {})
            @backend = options[:backend]
            @logger = options[:logger]
            @timeout = options[:timeout]
            @dead = false
            @load = 0
          end

          # This method spawns the backend and sends
          # an operation to connect to the backend to
          # an EventMachine Thread.
          def launch!(options = {})
            @launch_time = Time.now
            @connected_to_socket = false
            @backend.spawn!

            b = self
            estabconn = proc do
              b.establish_connection
            end
            estabconn_callback = proc do |res|
              logger.info("Connection to #{b.socket} dead #{b.dead}")
            end
            EM.defer(estabconn, estabconn_callback)
          end

          def terminate!
            backend.terminate!
          end

          def dead?
            @dead
          end

          def ready?
            @connected_to_socket && !@dead
          end

          def socket
            backend.socket
          end

          # I still wonder about this one.
          def on_connect(&callback)
            if block_given?
              @on_connect = callback
            elsif @on_connect
              @on_connect.call
            end
          end

          # Attempts to establish a connection to the backend
          # without doing anything. The backend only sets up
          # the socket once it has finished loading. So, if we
          # can connect, we are pretty much ready except probably
          # for any ruby AutoLoads of modules.
          #
          def establish_connection
            @connecting_to_socket = true
            start_time = Time.now
            while(@timeout.nil? || Time.now - start_time < @timeout )
              begin
                b = self
                srv = EventMachine::connect_unix_domain(self.socket, EventMachine::Connection, true) do |c|
                  logger.info("Connected to #{b.socket}")
                end
                @connected_to_socket = true
                @connecting_to_socket = false
                return
              rescue RuntimeError => e
                @connecting_to_socket = false
                sleep 5
              end
            end
            logger.warn("Backend #{socket} did not spin up in the required #{@timeout} seconds.")
            @dead = true
          end

          # We have a connection from the client.
          # Establish a server for this connection to relay to the backend.
          # We up the load on this backend as more an more connections get
          # pushed onto it. The EM framework takes care of queueing connections
          # and handing data.
          def connect(conn)
            b = self
            conn.on_connect do
              logger.debug "OnConnect for Backend ready at #{backend.socket} on Connection #{conn} load #{b.load}" if logger
              b.on_connect
              b.load += 1
            end

            conn.on_data do |data|
              logger.debug "OnData for Backend ready at #{backend.socket} on Connection #{conn} load #{b.load}." if logger
              data
            end

            conn.on_response do |backend, resp|
              logger.debug "OnResponse for Backend ready at #{backend.socket} on Connection #{conn} load #{b.load}." if logger
              resp
            end

            conn.on_finish do
              logger.debug "OnFinish for Backend ready at #{backend.socket} on Connection #{conn} load #{b.load}." if logger
              b.load -= 1
            end
            conn.server backend, :socket => backend.socket
            return true
          rescue RuntimeError => e
            logger.warn "#{e.message}" if logger
            return false
          end
        end

        # This server has gotten a connection from the client
        # We decide which backend to give it to.
        # TODO: A factory to recreate backends in the event that they die.
        def on_connection(conn)
          logger.debug "Server:on_connection #{conn}" if logger
          @backends.delete_if { |b| b.dead? }
          raise ::Heroku::Forward::Errors::BackendFailedToStartError.new if @backends.empty?
          # Find the one with the minimum load.
          b = @backends.select {|b| b.ready?}.reduce() { |t,v| t.load <= v.load ? t : v }
          # If there is no connection wait a bit and try again.
          if b
            prev_load = b.load
            if b.connect(conn)
              return
            else
              # This request is already toast. Just ignore, reset load.
              b.load = prev_load
            end
          else
            s = self
            logger.debug "Server: EM queuing #{conn} because no available backends yet." if logger
            EM.next_tick do
              #logger.info "Server: next_tick #{conn}." if logger
              sleep 1
              if @rejection_data
                s.reject_connection(conn)
              else
                s.on_connection(conn)
              end
            end
          end
        end

        class RejectConnection < EventMachine::Connection
          def receive_data(data)
            send_data @rejection_data
            close_connection(true)
          end
        end

        def reject_connection(conn)
          conn.server RejectConnection.new(@rejection_data)
        end

        #
        # This method runs the forwarder.
        #
        def forward!(options = {})
          logger.info "Launching Backends ..." if logger

          i = 0
          for backend in @backends
            i += 1
            backend.launch!
            logger.info "Launching Backend #{i} at #{backend.socket}." if logger
          end

          if @delay && (delay = @delay.to_i) > 0
            logger.info "Waiting #{delay}s to Launch Proxy Server ..." if logger
            sleep delay
          end

          logger.info "Launching Proxy Server at #{host}:#{port} ..." if logger
          s = self
          ::Proxy.start({ :host => host, :port => port, :debug => false }) do |conn|
              s.on_connection(conn)
          end

          logger.info "Proxy Server at #{host}:#{port} Finished." if logger
        end

        def stop!
          logger.info "Terminating Proxy Server" if logger
          EventMachine.stop
          logger.info "Terminating Web Server" if logger
          for b in backends do
            b.terminate!
          end
        end
      end
    end
  end
end
