# frozen_string_literal: true

# Copyright (c) 2018 Yegor Bugayenko
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the 'Software'), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED 'AS IS', WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

require 'concurrent'
require 'csv'
require 'uri'
require 'net/http'
require 'time'
require 'futex'
require 'fileutils'
require 'backtrace'
require_relative 'age'
require_relative 'score'
require_relative 'http'
require_relative 'node/farm'
require_relative 'type'

# The list of remotes.
# Author:: Yegor Bugayenko (yegor256@gmail.com)
# Copyright:: Copyright (c) 2018 Yegor Bugayenko
# License:: MIT
module Zold
  # All remotes
  class Remotes < Dry::Struct
    # The default TCP port all nodes are supposed to use.
    PORT = 4096

    # At what amount of errors we delete the remote automatically
    TOLERANCE = 8

    # Default number of nodes to fetch.
    MAX_NODES = 16

    attribute :file, Types::Strict::String
    attribute :network, Types::Strict::String.optional.default('test')
    attribute :timeout, Types::Strict::Integer.optional.default(16)

    # Empty, for standalone mode
    class Empty
      def initialize
        # Nothing to init here
      end

      def all
        []
      end

      def iterate(_)
        # Nothing to do here
      end

      def mtime
        Time.now
      end
    end

    # One remote.
    class Remote < Dry::Struct
      attribute :host, Types::Strict::String
      attribute :port, Types::Strict::Integer.constrained(gteq: 0, lt: 65_535)
      attribute :score, Score
      attribute :idx, Types::Strict::Integer
      attribute :network, Types::Strict::String.optional.default('test')
      attribute :log, (Types::Class.constructor do |value|
        value.nil? ? Log::Quiet.new : value
      end)

      def http(path = '/')
        Http.new(uri: "http://#{host}:#{port}#{path}", score: score, network: network)
      end

      def to_s
        "#{host}:#{port}/#{idx}"
      end

      def assert_code(code, response)
        msg = response.message.strip
        return if response.code.to_i == code
        if response.header['X-Zold-Error']
          raise "Error ##{response.code} \"#{response.header['X-Zold-Error']}\" at #{response.header['X-Zold-Path']}"
        end
        raise "Unexpected HTTP code #{response.code}, instead of #{code}" if msg.empty?
        raise "#{msg} (HTTP code #{response.code}, instead of #{code})"
      end

      def assert_valid_score(score)
        raise "Invalid score #{score}" unless score.valid?
        raise "Expired score (#{Age.new(score.time)}) #{score}" if score.expired?
      end

      def assert_score_ownership(score)
        raise "Masqueraded host #{host} as #{score.host}: #{score}" if host != score.host
        raise "Masqueraded port #{port} as #{score.port}: #{score}" if port != score.port
      end

      def assert_score_strength(score)
        raise "Score #{score.strength} is too weak (<#{Score::STRENGTH}): #{score}" if score.strength < Score::STRENGTH
      end

      def assert_score_value(score, min)
        raise "Score #{score.value} is too small (<#{min}): #{score}" if score.value < min
      end
    end

    def all
      list = load
      max_score = list.map { |r| r[:score] }.max || 0
      max_score = 1 if max_score.zero?
      max_errors = list.map { |r| r[:errors] }.max || 0
      max_errors = 1 if max_errors.zero?
      list.sort_by do |r|
        (1 - r[:errors] / max_errors) * 5 + (r[:score] / max_score)
      end.reverse
    end

    def clean
      modify { [] }
    end

    def defaults
      other = Remotes.new(file: File.expand_path(File.join(File.dirname(__FILE__), '../../resources/remotes')))
      other.all.each do |r|
        add(r[:host], r[:port])
      end
    end

    def exists?(host, port = Remotes::PORT)
      raise 'Port has to be of type Integer' unless port.is_a?(Integer)
      raise 'Host can\'t be nil' if host.nil?
      raise 'Port can\'t be nil' if port.nil?
      !load.find { |r| r[:host] == host.downcase && r[:port] == port }.nil?
    end

    def add(host, port = Remotes::PORT)
      raise 'Host can\'t be nil' if host.nil?
      raise 'Host can\'t be empty' if host.empty?
      raise 'Port can\'t be nil' if port.nil?
      raise 'Port has to be of type Integer' unless port.is_a?(Integer)
      raise 'Port can\'t be zero' if port.zero?
      raise 'Port can\'t be negative' if port.negative?
      raise 'Port can\'t be over 65536' if port > 0xffff
      modify do |list|
        list + [{ host: host.downcase, port: port, score: 0, errors: 0 }]
      end
    end

    def remove(host, port = Remotes::PORT)
      raise 'Port has to be of type Integer' unless port.is_a?(Integer)
      raise 'Host can\'t be nil' if host.nil?
      raise 'Port can\'t be nil' if port.nil?
      modify do |list|
        list.reject { |r| r[:host] == host.downcase && r[:port] == port }
      end
    end

    def iterate(log, farm: Farm::Empty.new)
      raise 'Log can\'t be nil' if log.nil?
      raise 'Farm can\'t be nil' if farm.nil?
      list = all
      return if list.empty?
      best = farm.best[0]
      require_relative 'score'
      score = best.nil? ? Score::ZERO : best
      idx = 0
      pool = Concurrent::FixedThreadPool.new([list.count, Concurrent.processor_count * 4].min, max_queue: 0)
      list.each do |r|
        pool.post do
          Thread.current.abort_on_exception = true
          Thread.current.name = "remotes-#{idx}@#{r[:host]}:#{r[:port]}"
          start = Time.now
          begin
            yield Remotes::Remote.new(
              host: r[:host],
              port: r[:port],
              score: score,
              idx: idx,
              log: log,
              network: network
            )
            raise 'Took too long to execute' if (Time.now - start).round > timeout
          rescue StandardError => e
            error(r[:host], r[:port])
            log.info("#{Rainbow("#{r[:host]}:#{r[:port]}").red}: #{e.message} in #{Age.new(start)}")
            log.debug(Backtrace.new(e).to_s)
            remove(r[:host], r[:port]) if errors > Remotes::TOLERANCE
          end
        end
        idx += 1
      end
      pool.shutdown
      pool.kill unless pool.wait_for_termination(5 * 60)
    end

    def error(host, port = Remotes::PORT)
      raise 'Host can\'t be nil' if host.nil?
      raise 'Port can\'t be nil' if port.nil?
      raise 'Port has to be of type Integer' unless port.is_a?(Integer)
      if_present(host, port) { |r| r[:errors] += 1 }
    end

    def rescore(host, port, score)
      raise 'Host can\'t be nil' if host.nil?
      raise 'Port can\'t be nil' if port.nil?
      raise 'Score can\'t be nil' if score.nil?
      raise 'Port has to be of type Integer' unless port.is_a?(Integer)
      if_present(host, port) { |r| r[:score] = score }
    end

    def mtime
      File.exist?(file) ? File.mtime(file) : Time.now
    end

    private

    def modify
      Futex.new(file).open do
        save(yield(load))
      end
    end

    def if_present(host, port)
      modify do |list|
        remote = list.find { |r| r[:host] == host.downcase && r[:port] == port }
        return unless remote
        yield remote
        list
      end
    end

    def load
      if File.exist?(file)
        raw = CSV.read(file).map do |row|
          {
            host: row[0],
            port: row[1].to_i,
            score: row[2].to_i,
            errors: row[3].to_i
          }
        end
        raw.reject { |r| !r[:host] || r[:port].zero? }.map do |r|
          r[:home] = URI("http://#{r[:host]}:#{r[:port]}/")
          r
        end
      else
        []
      end
    end

    def save(list)
      FileUtils.mkdir_p(File.dirname(file))
      IO.write(
        file,
        list.uniq { |r| "#{r[:host]}:#{r[:port]}" }.map do |r|
          [
            r[:host],
            r[:port],
            r[:score],
            r[:errors]
          ].join(',')
        end.join("\n")
      )
    end
  end
end
