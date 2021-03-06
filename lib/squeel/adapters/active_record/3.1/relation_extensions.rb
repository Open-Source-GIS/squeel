require 'active_record'

module Squeel
  module Adapters
    module ActiveRecord
      module RelationExtensions

        JoinAssociation = ::ActiveRecord::Associations::JoinDependency::JoinAssociation
        JoinDependency = ::ActiveRecord::Associations::JoinDependency

        attr_writer :join_dependency
        private :join_dependency=

        # Returns a JoinDependency for the current relation.
        #
        # We don't need to clear out @join_dependency by overriding #reset, because
        # the default #reset already does this, despite never setting it anywhere that
        # I can find. Serendipity, I say!
        def join_dependency
          @join_dependency ||= (build_join_dependency(table.from(table), @joins_values) && @join_dependency)
        end

        def predicate_visitor
          Visitors::PredicateVisitor.new(
            Context.new(join_dependency)
          )
        end

        def attribute_visitor
          Visitors::AttributeVisitor.new(
            Context.new(join_dependency)
          )
        end

        # We need to be able to support merging two relations without having
        # to get our hooks too deeply into ActiveRecord. AR's relation
        # merge functionality is very cool, but relatively complex, to
        # handle the various edge cases. Our best shot at avoiding strange
        # behavior with Squeel loaded is to visit the *_values arrays in
        # the relations we're merging, and then use the default AR merge
        # code on the result.
        def merge(r, skip_visit = false)
          if skip_visit or not ::ActiveRecord::Relation === r
            super(r)
          else
            visited.merge(r.visited, true)
          end
        end

        def visited
          clone.visit!
        end

        def visit!
          predicate_viz = predicate_visitor
          attribute_viz = attribute_visitor

          @where_values = predicate_viz.accept((@where_values - ['']).uniq)
          @having_values = predicate_viz.accept(@having_values.uniq.reject{|h| h.blank?})
          # FIXME: AR barfs on ARel attributes in group_values. Workaround?
          # @group_values = attribute_viz.accept(@group_values.uniq.reject{|g| g.blank?})
          @order_values = attribute_viz.accept(@order_values.uniq.reject{|o| o.blank?})
          @select_values = attribute_viz.accept(@select_values.uniq)

          self
        end

        def build_arel
          arel = table.from table

          build_join_dependency(arel, @joins_values) unless @joins_values.empty?

          predicate_viz = predicate_visitor
          attribute_viz = attribute_visitor

          collapse_wheres(arel, predicate_viz.accept((@where_values - ['']).uniq))

          arel.having(*predicate_viz.accept(@having_values.uniq.reject{|h| h.blank?})) unless @having_values.empty?

          arel.take(connection.sanitize_limit(@limit_value)) if @limit_value
          arel.skip(@offset_value) if @offset_value

          arel.group(*attribute_viz.accept(@group_values.uniq.reject{|g| g.blank?})) unless @group_values.empty?

          order = @reorder_value ? @reorder_value : @order_values
          order = attribute_viz.accept(order)
          order = reverse_sql_order(attrs_to_orderings(order)) if @reverse_order_value
          arel.order(*order.uniq.reject{|o| o.blank?}) unless order.empty?

          build_select(arel, attribute_viz.accept(@select_values.uniq))

          arel.from(@from_value) if @from_value
          arel.lock(@lock_value) if @lock_value

          arel
        end

        # reverse_sql_order will reverse the order of strings or Orderings,
        # but not attributes
        def attrs_to_orderings(order)
          order.map do |o|
            Arel::Attribute === o ? o.asc : o
          end
        end

        # So, building a select for a count query in ActiveRecord is
        # pretty heavily dependent on select_values containing strings.
        # I'd initially expected that I could just hack together a fix
        # to select_for_count and everything would fall in line, but
        # unfortunately, pretty much everything from that point on
        # in ActiveRecord::Calculations#perform_calculation expects
        # the column to be a string, or at worst, a symbol.
        #
        # In the long term, I would like to refactor the code in
        # Rails core, but for now, I'm going to settle for this hack
        # that tries really hard to coerce things to a string.
        def select_for_count
          visited_values = attribute_visitor.accept(select_values.uniq)
          if visited_values.size == 1
            select = visited_values.first

            str_select = case select
            when String
              select
            when Symbol
              select.to_s
            else
              select.to_sql if select.respond_to?(:to_sql)
            end

            str_select if str_select && str_select !~ /[,*]/
          end
        end

        def build_join_dependency(manager, joins)
          buckets = joins.group_by do |join|
            case join
            when String
              'string_join'
            when Hash, Symbol, Array, Nodes::Stub, Nodes::Join, Nodes::KeyPath
              'association_join'
            when JoinAssociation
              'stashed_join'
            when Arel::Nodes::Join
              'join_node'
            else
              raise 'unknown class: %s' % join.class.name
            end
          end

          association_joins         = buckets['association_join'] || []
          stashed_association_joins = buckets['stashed_join'] || []
          join_nodes                = (buckets['join_node'] || []).uniq
          string_joins              = (buckets['string_join'] || []).map { |x|
            x.strip
          }.uniq

          join_list = join_nodes + custom_join_ast(manager, string_joins)

          # All of that duplication just to do this...
          self.join_dependency = JoinDependency.new(
            @klass,
            association_joins,
            join_list
          )

          join_dependency.graft(*stashed_association_joins)

          @implicit_readonly = true unless association_joins.empty? && stashed_association_joins.empty?

          join_dependency.join_associations.each do |association|
            association.join_to(manager)
          end

          manager.join_sources.concat join_list

          manager
        end

        def includes(*args)
          if block_given? && args.empty?
            super(DSL.eval &Proc.new)
          else
            super
          end
        end

        def preload(*args)
          if block_given? && args.empty?
            super(DSL.eval &Proc.new)
          else
            super
          end
        end

        def eager_load(*args)
          if block_given? && args.empty?
            super(DSL.eval &Proc.new)
          else
            super
          end
        end

        def select(value = Proc.new)
          if block_given? && Proc === value
            if value.arity > 0
              to_a.select {|*block_args| value.call(*block_args)}
            else
              relation = clone
              relation.select_values += Array.wrap(DSL.eval &value)
              relation
            end
          else
            super
          end
        end

        def group(*args)
          if block_given? && args.empty?
            super(DSL.eval &Proc.new)
          else
            super
          end
        end

        def order(*args)
          if block_given? && args.empty?
            super(DSL.eval &Proc.new)
          else
            super
          end
        end

        def reorder(*args)
          if block_given? && args.empty?
            super(DSL.eval &Proc.new)
          else
            super
          end
        end

        def joins(*args)
          if block_given? && args.empty?
            super(DSL.eval &Proc.new)
          else
            super
          end
        end

        def where(opts = Proc.new, *rest)
          if block_given? && Proc === opts
            super(DSL.eval &opts)
          else
            super
          end
        end

        def having(*args)
          if block_given? && args.empty?
            super(DSL.eval &Proc.new)
          else
            super
          end
        end

        def build_where(opts, other = [])
          case opts
          when String, Array
            super
          else  # Let's prevent PredicateBuilder from doing its thing
            [opts, *other].map do |arg|
              case arg
              when Array  # Just in case there's an array in there somewhere
                @klass.send(:sanitize_sql, arg)
              when Hash
                @klass.send(:expand_hash_conditions_for_aggregates, arg)
              else
                arg
              end
            end
          end
        end

        def collapse_wheres(arel, wheres)
          wheres = Array(wheres)
          binaries = wheres.grep(Arel::Nodes::Binary)

          groups = binaries.group_by {|b| [b.class, b.left]}

          groups.each do |_, bins|
            arel.where(Arel::Nodes::And.new(bins))
          end

          (wheres - binaries).each do |where|
            where = Arel.sql(where) if String === where
            arel.where(Arel::Nodes::Grouping.new(where))
          end
        end

        def find_equality_predicates(nodes)
          nodes.map { |node|
            case node
            when Arel::Nodes::Equality
              node if node.left.relation.name == table_name
            when Arel::Nodes::Grouping
              find_equality_predicates([node.expr])
            when Arel::Nodes::And
              find_equality_predicates(node.children)
            else
              nil
            end
          }.compact.flatten
        end

        def flatten_nodes(nodes)
          nodes.map { |node|
            case node
            when Array
              flatten_nodes(node)
            when Nodes::And
              flatten_nodes(node.children)
            when Nodes::Grouping
              flatten_nodes(node.expr)
            else
              node
            end
          }.flatten
        end

        def overwrite_squeel_equalities(wheres)
          seen = {}
          flatten_nodes(wheres).reverse.reject { |n|
            nuke = false
            if Nodes::Predicate === n && n.method_name == :eq
              nuke       = seen[n.expr]
              seen[n.expr] = true
            end
            nuke
          }.reverse
        end

        # Simulate the logic that occurs in #to_a
        #
        # This will let us get a dump of the SQL that will be run against the
        # DB for debug purposes without actually running the query.
        def debug_sql
          if eager_loading?
            including = (@eager_load_values + @includes_values).uniq
            join_dependency = JoinDependency.new(@klass, including, [])
            construct_relation_for_association_find(join_dependency).to_sql
          else
            arel.to_sql
          end
        end

        ### ZOMG ALIAS_METHOD_CHAIN IS BELOW. HIDE YOUR EYES!
        # ...
        # ...
        # ...
        # Since you're still looking, let me explain this horrible
        # transgression you see before you.
        #
        # You see, Relation#where_values_hash and with_default_scope
        # are defined on the ActiveRecord::Relation class, itself.
        # ActiveRecord::Relation class. Since they're defined there, but
        # I would very much like to modify their behavior, I have three
        # choices.
        #
        # 1. Inherit from ActiveRecord::Relation in a Squeel::Relation
        #    class, and make an attempt to usurp all of the various calls
        #    to methods on ActiveRecord::Relation by doing some really
        #    evil stuff with constant reassignment, all for the sake of
        #    being able to use super().
        #
        # 2. Submit a patch to Rails core, breaking these methods off into
        #    another module, all for my own selfish desire to use super()
        #    while mucking about in Rails internals.
        #
        # 3. Use alias_method_chain, and say 10 hail Hanssons as penance.
        #
        # I opted to go with #3. Except for the hail Hansson thing.
        # Unless you're DHH, in which case, I totally said them.
        #
        # If you'd like to read more about alias_method_chain, see
        # http://erniemiller.org/2011/02/03/when-to-use-alias_method_chain/

        def self.included(base)
          base.class_eval do
            alias_method_chain :where_values_hash, :squeel
            alias_method_chain :with_default_scope, :squeel
          end
        end

        # where_values_hash is used in scope_for_create. It's what allows
        # new records to be created with any equality values that exist in
        # your model's default scope. We hijack it in order to dig down into
        # And and Grouping nodes, which are equivalent to seeing top-level
        # Equality nodes in stock AR terms.
        def where_values_hash_with_squeel
          equalities = find_equality_predicates(predicate_visitor.accept(with_default_scope.where_values))

          Hash[equalities.map { |where| [where.left.name, where.right] }]
        end

        # with_default_scope was added to ActiveRecord ~> 3.1 in order to
        # address https://github.com/rails/rails/issues/1233. Unfortunately,
        # it plays havoc with Squeel's approach of visiting both sides of
        # a relation merge. Thankfully, when merging with a relation from
        # the same AR::Base, it's unnecessary to visit...
        #
        # Except, of course, this means we have to handle the edge case
        # where equalities are duplicated on both sides of the merge, in
        # which case, unlike all other chained relation calls, the latter
        # equality overwrites the former.
        #
        # The workaround using overwrite_squeel_equalities works as long
        # as you stick to the Squeel DSL, but breaks down if you throw hash
        # conditions into the mix. If anyone's got any suggestions, I'm all
        # ears. Otherwise, just stick to the Squeel DSL.
        #
        # Or, don't use default scopes. They're the devil, anyway. I can't
        # remember the last time I used one and didn't find myself
        # regretting the decision later.
        def with_default_scope_with_squeel
          if default_scoped? &&
            default_scope = klass.build_default_scope_with_squeel
            default_scope = default_scope.merge(self, true)
            default_scope.default_scoped = false
            default_scope.where_values = overwrite_squeel_equalities(
              default_scope.where_values + self.where_values
            )
            default_scope
          else
            self
          end
        end

      end
    end
  end
end
