# frozen_string_literal: true

module Cent
  # Where the publication went in the channel's stream.
  class PublishResult
    # @return [StreamPosition] the publication's offset and the stream's epoch:
    #   the since of a history call reading what came after it
    def position = StreamPosition.new(offset:, epoch:)
  end

  # The channel's stream position when the history was read.
  class HistoryResult
    # @return [StreamPosition] the stream's top offset and epoch
    def position = StreamPosition.new(offset:, epoch:)
  end

  # The map channel's stream position when its state was read.
  class MapReadStateResult
    # @return [StreamPosition] the stream's offset and epoch: as map_read_stream's
    #   since_offset and since_epoch, it reads the changes since
    def position = StreamPosition.new(offset:, epoch:)
  end

  # The map channel's stream position when its stream was read.
  class MapReadStreamResult
    # @return [StreamPosition] the stream's offset and epoch
    def position = StreamPosition.new(offset:, epoch:)
  end

  # The map channel's stream position after the publication.
  class MapPublishResult
    # @return [StreamPosition] the publication's offset in the map's stream and
    #   the stream's epoch
    def position = StreamPosition.new(offset:, epoch:)
  end

  # The map channel's stream position after the removal.
  class MapRemoveResult
    # @return [StreamPosition] the removal's offset in the map's stream and the
    #   stream's epoch
    def position = StreamPosition.new(offset:, epoch:)
  end

  # The <method>_all iterators of Client (spec 3.8): paging written once over
  # the cursor, and once for history.
  #
  # @api private
  module Pages
    # Each paged method's result type, the field of its items, and the field
    # holding the next page's cursor - empty when there is none.
    PAGED = {
      "history" => [HistoryResult, :publications, nil],
      "device_list" => [DeviceListResult, :items, :next_cursor],
      "device_topic_list" => [DeviceTopicListResult, :items, :next_cursor],
      "user_topic_list" => [UserTopicListResult, :items, :next_cursor],
      "map_read_state" => [MapReadStateResult, :entries, :cursor]
    }.freeze

    private

    # The items of every page of +method+, the first page's request the JSON
    # the block builds: an Enumerator, or each yielded to +block+. The request
    # is checked here, before anything is sent.
    def pages(method, timeout, block, &)
      first = encode_request(method, &)
      check_history(first) if method == "history"
      return Enumerator.new { |y| each_page(method, first, timeout) { y << it } } unless block

      each_page(method, first, timeout, &block)
      nil
    end

    def check_history(w)
      limit = w["limit"] || 0
      if limit < 1
        raise InvalidRequestError, "invalid history request: history_all needs a limit of 1 or more, the page size " \
                                   "(0 asks for the position alone, -1 for everything in one call)"
      end
      return unless w["reverse"]

      raise InvalidRequestError, "invalid history request: history_all reads forward only: reverse is not supported"
    end

    def each_page(method, w, timeout, &)
      result_class, items, cursor = PAGED.fetch(method)
      # map_read_state's later pages are read at the first page's revision,
      # unless the request pins one itself.
      pin = method == "map_read_state" && !w.key?("revision_offset") && !w.key?("revision_epoch")
      loop do
        res = invoke(method, result_class, timeout) { w }
        page = res.public_send(items)
        page.each(&)
        if cursor.nil?
          break if page.size < w["limit"]

          w = w.merge("since" => position(page.last.offset, res.epoch))
        else
          following = res.public_send(cursor)
          break if following.empty?

          w = w.merge("cursor" => following)
          if pin
            w = w.merge(position(res.offset, res.epoch).transform_keys { "revision_#{it}" })
            pin = false
          end
        end
      end
    end

    # A stream position as the JSON of a request, zero values left out.
    def position(offset, epoch)
      w = {}
      w["offset"] = offset unless offset.zero?
      w["epoch"] = epoch unless epoch.empty?
      w
    end
  end
end
