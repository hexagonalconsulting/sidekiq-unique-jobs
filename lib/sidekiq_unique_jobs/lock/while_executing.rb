require "redis-classy"
require "redis-mutex"
module SidekiqUniqueJobs
  module Lock
    class WhileExecuting
      def self.synchronize(item, redis_pool = nil)
        new(item, redis_pool).synchronize { yield }
      end

      def initialize(item, redis_pool = nil)
        @item = item
        @mutex = Mutex.new
        @redis_pool = redis_pool
        @unique_digest = "#{create_digest}:run"
      end

      def synchronize
        @mutex.lock
        RedisClassy.redis = SidekiqUniqueJobs.connection(@redis_pool) {|redis| redis}
        mutex = RedisMutex.new(@unique_digest, block: 0, expire: max_lock_time)

        if mutex.lock
          begin
            yield
          ensure
            mutex.unlock
          end
        else
          SidekiqUniqueJobs.connection(@redis_pool) do |c|
            @item["class"].constantize.perform_at(2.minute, *@item["unique_args"])
          end
        end
      rescue Sidekiq::Shutdown
        logger.fatal { "the unique_key: #{@unique_digest} needs to be unlocked manually" }
        raise
      ensure
        @mutex.unlock
      end

      def get_lock?
        begin
          SidekiqUniqueJobs.connection(@redis_pool) do |redis|
            res = redis.client.call([:set,@unique_digest,Time.now.to_i + max_lock_time,:nx,:px,max_lock_time])
          end
          true
        rescue => e
          puts e
          return false
        end
      end

      def max_lock_time
        @max_lock_time ||= RunLockTimeoutCalculator.for_item(@item).seconds
      end

      def execute(_callback)
        synchronize do
          yield
        end
      end

      def create_digest
        @unique_digest ||= @item[UNIQUE_DIGEST_KEY]
        @unique_digest ||= SidekiqUniqueJobs::UniqueArgs.digest(@item)
      end
    end
  end
end
