# encoding: ascii-8bit

# Copyright 2014 Ball Aerospace & Technologies Corp.
# All Rights Reserved.
#
# This program is free software; you can modify and/or redistribute it
# under the terms of the GNU General Public License
# as published by the Free Software Foundation; version 3 with
# attribution addendums as found in the LICENSE.txt

require 'cosmos'
require 'cosmos/script'
require 'cosmos/gui/qt'
require 'cosmos/gui/text/completion_text_edit'

module Cosmos

  class RubyEditor < CompletionTextEdit
    slots 'line_count_changed()'
    slots 'update_line_number_area(const QRect &, int)'
    signals 'breakpoint_set(int)'
    signals 'breakpoint_cleared(int)'
    signals 'breakpoints_cleared()'

    attr_accessor :enable_breakpoints

    # This works but slows down the GUI significantly when pasting a large (10k line) block of code into the editor
    class RubySyntax < Qt::SyntaxHighlighter
      # Ruby keywords - http://www.ruby-doc.org/docs/keywords/1.9/
      # Also include some common methods that are typically called by
      # themselves like puts, print, sleep
      RUBY_KEYWORDS = %w(BEGIN END __ENCODING__ __END__ __FILE__ __LINE__ \
                         alias and begin break case class def defined? do \
                         else elsif end ensure false for if in module \
                         next nil not or raise redo rescue retry return \
                         self super then true undef unless until when while yield \
                         puts print sleep) # common stand alone methods

      def self.create_format(color = Cosmos::BLACK, style='')
        color = Cosmos::getColor(color)
        brush = Cosmos::getBrush(color)

        format = Qt::TextCharFormat.new
        format.setForeground(brush)
        if style == 'bold'
          format.setFontWeight(Qt::Font::Bold)
        end
        if style == 'italic'
          format.setFontItalic(true)
        end
        format
      end

      # Syntax styles - refer to the ruby.properties in Scite
      STYLES = {
        'normal' => create_format('black'),
        'ruby_keyword' => create_format('darkBlue','bold'),
        'cosmos_keyword' => create_format('blue','bold'),
        'operator' => create_format('red'),
        'brace' => create_format('black','bold'),
        'class' => create_format('blue', 'bold'),
        'method' => create_format(Cosmos::getColor(0, 127, 127), 'bold'),
        'string' => create_format(Cosmos::getColor(127, 0, 127)),
        'symbol' => create_format(Cosmos::getColor(192,160,48)),
        'comment' => create_format('green'),
      }

      # Ruby braces
      BRACES = ['\{', '\}', '\(', '\)', '\[', '\]','\|']

      RULES = []
      RUBY_KEYWORDS.each do |w|
        RULES << ['\b'+w+'\b', 0, STYLES['ruby_keyword']]
      end
      Script.private_instance_methods.each do |w|
        RULES << ['\b'+w.to_s+'\b', 0, STYLES['cosmos_keyword']]
      end
      BRACES.each do |b|
        RULES << ["#{b}", 0, STYLES['brace']]
      end
      RULES.concat([
          # 'def' followed by an identifier
          ['\bdef\b\s*(\w+)', 1, STYLES['method']],
          # 'class' followed by an identifier
          ['\bclass\b\s*(\w+)', 1, STYLES['class']],
          # Ruby symbol
          [':\b\w+', 0, STYLES['symbol']],
          # Ruby global
          ['\\$\b\w+', 0, STYLES['string']],
          # A single # or a # not followed by { to the end
          ['(#$|#[^{]).*', 0, STYLES['comment']],
          # Regex, possibly containing escape sequences
          ["/.*/", 0, STYLES['string']],
          # Double-quoted string, possibly containing escape sequences
          ['"([^"\\\\]|\\\\.)*"', 0, STYLES['string']],
          # Match interpolated strings "blah #{code} blah"
          ['(\#\\{)[^\\}]*\\}', 1, STYLES['brace']],
          ['\#\\{[^\\}]*(\\})', 1, STYLES['brace']],
          ['\#\\{([^\\}]*)\\}', 1, STYLES['normal']],
          # Single-quoted string, possibly containing escape sequences
          ["'[^'\\\\]*(\\.[^'\\\\]*)*'", 0, STYLES['string']],
          # Back-tick string, possibly containing escape sequences
          ["`[^`\\\\]*(\\.[^`\\\\]*)*`", 0, STYLES['string']],
      ])

      # Build a QRegExp for each pattern
      RULES_INFO = []
      RULES.each do |pat, index, fmt|
        RULES_INFO << [Qt::RegExp.new(pat, Qt::CaseSensitive, Qt::RegExp::RegExp2), index, fmt]
      end

      def highlightBlock(text)
        # Do other syntax formatting
        RULES_INFO.each do |expression, nth, format|
          index = expression.indexIn(text, 0)
          last_index = index
          last_length = -1
          while index >= 0
            # We actually want the index of the nth match
            index = expression.pos(nth)
            # Bail if the index goes negative because it means
            # we won't have a valid capture
            break if index < 0
            length = expression.cap(nth).length()
            break if length <= 0
            # Break if we're in an endless loop
            break if (last_index == index and last_length == length)
            last_length = length
            last_index = index
            self.setFormat(index, length, format)
            index = expression.indexIn(text, index + length)
          end
        end
      end
    end

    class LineNumberArea < Qt::Widget
      def initialize(editor)
        super(editor)
        @codeEditor = editor
        self
      end

      def sizeHint()
        return Qt::Size(@codeEditor.lineNumberAreaWidth(), 0)
      end

      def paintEvent(event)
        @codeEditor.lineNumberAreaPaintEvent(event)
      end
    end

    CHAR_57 = Qt::Char.new(57)

    def initialize(parent)
      super(parent)
      if Kernel.is_windows?
        setFont(Cosmos.getFont("Courier", 10))
        @fontMetrics = Cosmos.getFontMetrics(Cosmos.getFont("Courier", 10))
      else
        setFont(Cosmos.getFont("Courier", 14))
        @fontMetrics = Cosmos.getFontMetrics(Cosmos.getFont("Courier", 14))
      end

      # This is needed so text searching highlights correctly
      setStyleSheet("selection-background-color: lightblue; selection-color: black;")

      @breakpoints = []
      @enable_breakpoints = false

      # RubySyntax works but slows down the GUI significantly when pasting a large (10k line) block of code into the editor
      @syntax = RubySyntax.new(document())
      @lineNumberArea = LineNumberArea.new(self)

      connect(self, SIGNAL('blockCountChanged(int)'), self, SLOT('line_count_changed()'))
      connect(self, SIGNAL('updateRequest(const QRect &, int)'), self, SLOT('update_line_number_area(const QRect &, int)'))

      line_count_changed()
    end

    def dispose
      super()
      @syntax.dispose
      @lineNumberArea.dispose
    end

    def context_menu(point)
      menu = createStandardContextMenu()
      if @enable_breakpoints
        menu.addSeparator()

        add_breakpoint = Qt::Action.new(tr("Add Breakpoint"), self)
        add_breakpoint.statusTip = tr("Add a breakpoint at this line")
        add_breakpoint.connect(SIGNAL('triggered()')) { breakpoint_click(point) }
        menu.addAction(add_breakpoint)

        clear_breakpoint = Qt::Action.new(tr("Clear Breakpoint"), self)
        clear_breakpoint.statusTip = tr("Clear an existing breakpoint at this line")
        clear_breakpoint.connect(SIGNAL('triggered()')) { breakpoint_click(point, false) }
        menu.addAction(clear_breakpoint)

        clear_all_breakpoints = Qt::Action.new(tr("Clear All Breakpoints"), self)
        clear_all_breakpoints.statusTip = tr("Clear all existing breakpoints")
        clear_all_breakpoints.connect(SIGNAL('triggered()')) do
          clear_breakpoints()
          emit breakpoints_cleared
        end
        menu.addAction(clear_all_breakpoints)
      end
      return menu
    end

    def breakpoint_click(point, add_breakpoint = true)
      line = point.y / @fontMetrics.height() + 1 + firstVisibleBlock().blockNumber()
      if add_breakpoint
        if line <= document.blockCount()
          breakpoint(line)
          emit breakpoint_set(line)
        end
      else
        if line <= document.blockCount()
          clear_breakpoint(line)
          emit breakpoint_cleared(line)
        end
      end
    end

    def breakpoint(line)
      @breakpoints << line
      @lineNumberArea.repaint
    end

    def clear_breakpoint(line)
      @breakpoints.delete(line)
      @lineNumberArea.repaint
    end

    def clear_breakpoints
      @breakpoints = []
      @lineNumberArea.repaint
    end

    def comment_or_uncomment_lines
      cursor = textCursor
      # Figure out if the cursor has a selection
      no_selection = true
      no_selection = false if cursor.hasSelection

      # Start the edit block so this can be all undone with a single undo step
      cursor.beginEditBlock
      selection_end = cursor.selectionEnd
      # Initially place the cursor at the beginning of the selection
      # If nothing is selected this will just put the cursor at the beginning of the current line
      cursor.setPosition(textCursor.selectionStart)
      cursor.movePosition(Qt::TextCursor::StartOfLine)
      result = true
      while (cursor.position < selection_end and result == true) or (no_selection)
        # Check for a special comment
        if cursor.block.text =~ /^\S*#~/
          cursor.deleteChar
          cursor.deleteChar
          # Since we deleted two spaces we need to move the end position by two
          selection_end -= 2
        else
          cursor.insertText("#~")
          # Since we deleted two spaces we need to move the end position by two
          selection_end += 2
        end
        # Move the cursor to the beginning of the next line
        cursor.movePosition(Qt::TextCursor::StartOfLine)
        result = cursor.movePosition(Qt::TextCursor::Down)
        # If nothing was selected then we're working with a single line and we can break
        break if no_selection
      end
      cursor.endEditBlock
    end

    def lineNumberAreaWidth
      digits = 1
      my_document = document()
      max = [1, my_document.blockCount()].max

      # Figure the line number power of ten to determine how much space we need
      while (max >= 10)
        max /= 10
        digits += 1
      end
      # We'll always display space for 5 digits so the line number area
      # isn't constantly expanding and contracting
      digits = 5 if digits < 5
      digits += 1 # always allow room for a breakpoint symbol
      # Get the font width of the character 57 ('9')
      # times the number of digits to display
      return (3 + @fontMetrics.width(CHAR_57) * digits)
    end

    def line_count_changed
      setViewportMargins(lineNumberAreaWidth(), 0, 0, 0)
      update
    end

    def update_line_number_area(rect, dy)
      if (dy)
        @lineNumberArea.scroll(0, dy)
      else
        @lineNumberArea.update(0, rect.y(), @lineNumberArea.width(), rect.height())
      end
      my_viewport = viewport()
      viewport_rect = my_viewport.rect()
      line_count_changed() if (rect.contains(viewport_rect))
      viewport_rect.dispose
    end

    def resizeEvent(e)
      super(e)
      cr = self.contentsRect()
      rect = Qt::Rect.new(cr.left(),
        cr.top(),
        lineNumberAreaWidth(),
        cr.height())
      @lineNumberArea.setGeometry(rect)
      cr.dispose
      rect.dispose
    end

    def lineNumberAreaPaintEvent(event)
      painter = Qt::Painter.new(@lineNumberArea)
      # On initialization sometimes we get some weird bad conditions so check for them
      if painter.isActive and not painter.paintEngine.nil?
        event_rect = event.rect()
        painter.fillRect(event_rect, Qt::lightGray)

        block = firstVisibleBlock()
        blockNumber = block.blockNumber()

        offset = contentOffset()
        rect = blockBoundingGeometry(block)
        rect2 = rect.translated(offset)
        top = rect2.top()
        rect3 = blockBoundingRect(block)
        bottom = top + rect3.height()
        offset.dispose
        offset = nil
        rect.dispose
        rect = nil
        rect2.dispose
        rect2 = nil
        rect3.dispose
        rect3 = nil

        width = @lineNumberArea.width()
        height = @fontMetrics.height()
        ellipse_width = @fontMetrics.width(CHAR_57)
        painter.setPen(Cosmos::BLACK)
        while (block.isValid() and top <= event_rect.bottom())
          if (block.isVisible() and bottom >= event_rect.top())
            number = blockNumber + 1
            painter.drawText(0,               # x
                             top,             # y
                             width,           # width
                             height,          # height
                             Qt::AlignRight,  # flags
                             number.to_s)     # text

            if @enable_breakpoints and @breakpoints.include?(number)
              painter.setBrush(Cosmos::RED)
              painter.drawEllipse(2,
                                  top+2,
                                  ellipse_width,
                                  ellipse_width)
            end
          end

          next_block = block.next()
          block.dispose
          block = next_block
          top = bottom
          rect = blockBoundingRect(block)
          bottom = top + rect.height()
          rect.dispose
          blockNumber += 1
        end
        block.dispose
        block = nil
        event_rect.dispose
        event_rect = nil
      end
      # Ensure the painter is disposed in the paint function to avoid this:
      #   QPaintDevice: Cannot destroy paint device that is being painted
      painter.dispose
      painter = nil
    end
  end

end # module Cosmos
