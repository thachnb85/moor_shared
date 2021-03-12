// don't import moor_web.dart or moor_flutter/moor_flutter.dart in shared code
import 'package:moor/moor.dart';
import 'package:undo/undo.dart';

import 'db_utils.dart';

export 'database/shared.dart';

part 'database.g.dart';

@DataClassName('TodoEntry')
class Todos extends Table {
  IntColumn get id => integer().autoIncrement()();

  TextColumn get content => text()();

  DateTimeColumn get targetDate => dateTime().nullable()();

  TextColumn get jsonData => text().nullable()();

  IntColumn get category => integer()
      .nullable()
      .customConstraint('NULLABLE REFERENCES categories(id)')();
}

@DataClassName('Category')
class Categories extends Table {
  IntColumn get id => integer().autoIncrement()();

  TextColumn get description => text().named('desc')();
}

class CategoryWithCount {
  CategoryWithCount(this.category, this.count);

  // can be null, in which case we count how many entries don't have a category
  final Category category;
  final int count; // amount of entries in this category
}

class EntryWithCategory {
  EntryWithCategory(this.entry, this.category);

  final TodoEntry entry;
  final Category category;
}

@UseMoor(
  tables: [Todos, Categories],
  queries: {
    '_resetCategory': 'UPDATE todos SET category = NULL WHERE category = ?',
  },
)
class Database extends _$Database {
  Database(QueryExecutor e) : super(e);
  final cs = ChangeStack();

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration {
    return MigrationStrategy(
      onCreate: (Migrator m) {
        return m.createAll();
      },
      onUpgrade: (Migrator m, int from, int to) async {
        if (from == 1) {
          await m.addColumn(todos, todos.targetDate);
        }
      },
      beforeOpen: (details) async {
        if (details.wasCreated) {
          // create default categories and entries
          final workId = await into(categories)
              .insert(const CategoriesCompanion(description: Value('Work')));

          // insert some example data
          for(int i = 0; i < 5; i++){
            await into(todos).insert(TodosCompanion(
                content: Value('Todo entry $i'),
                targetDate: Value(DateTime.now()),
                jsonData: Value('"{"index":"$i"}"')
            ));
          }

          print('---------------select EVERYTHING');
          List<TodoEntry> tds = await selectEverything();
          for(TodoEntry td in tds){
            print(td.jsonData);
          }

          print('---------------select something');
          TodoEntry td = await selectSomething();
          print(td.jsonData);

        }
      },
    );
  }

  Future<List<TodoEntry>> selectEverything() {
    return customSelect(
        'SELECT * FROM todos',
        readsFrom: {todos}
    ).map((row){
      return TodoEntry.fromData(row.data, this);
    }).get();
  }

  Future<TodoEntry> selectSomething() {
    // This custom select works perfect:
    //return (select(todos)..where((tbl) => tbl.id.equals(2))).getSingle();

    // but this json function doesn't work
    return customSelect(
        'SELECT * FROM todos WHERE json_extract(todos.json_data, \'\$.index\') = \'2\'',
        readsFrom: {todos}
    ).map((row){
      return TodoEntry.fromData(row.data, this);
    }).getSingle();
  }

  Stream<List<CategoryWithCount>> categoriesWithCount() {
    // select all categories and load how many associated entries there are for
    // each category
    return customSelect(
      'SELECT c.id, c.desc, '
      '(SELECT COUNT(*) FROM todos WHERE category = c.id) AS amount '
      'FROM categories c '
      'UNION ALL SELECT null, null, '
      '(SELECT COUNT(*) FROM todos WHERE category IS NULL)',
      readsFrom: {todos, categories},
    ).map((row) {
      // when we have the result set, map each row to the data class
      final hasId = row.data['id'] != null;

      return CategoryWithCount(
        hasId ? Category.fromData(row.data, this) : null,
        row.readInt('amount'),
      );
    }).watch();
  }

  /// Watches all entries in the given [category]. If the category is null, all
  /// entries will be shown instead.
  Stream<List<EntryWithCategory>> watchEntriesInCategory(Category category) {
    final query = select(todos).join(
        [leftOuterJoin(categories, categories.id.equalsExp(todos.category))]);

    if (category != null) {
      query.where(categories.id.equals(category.id));
    } else {
      query.where(isNull(categories.id));
    }

    return query.watch().map((rows) {
      // read both the entry and the associated category for each row
      return rows.map((row) {
        return EntryWithCategory(
          row.readTable(todos),
          row.readTable(categories),
        );
      }).toList();
    });
  }

  Future createEntry(TodosCompanion entry) async {
    final _todos = await (select(todos)
          ..orderBy([
            (u) => OrderingTerm(expression: u.id, mode: OrderingMode.desc),
          ]))
        .get();
    entry = entry.copyWith(id: Value(_todos.first.id + 1));
    return insertRow(cs, todos, entry);
  }

  /// Updates the row in the database represents this entry by writing the
  /// updated data.
  Future updateEntry(TodoEntry entry) async {
    return updateRow(cs, todos, entry);
  }

  Future deleteEntry(TodoEntry entry) {
    return deleteRow(cs, todos, entry);
  }

  Future<int> createCategory(String description) {
    return insertRow(
      cs,
      categories,
      CategoriesCompanion(description: Value(description)),
    );
  }

  Future deleteCategory(Category category) {
    return transaction(() async {
      await _resetCategory(category.id);
      await deleteRow(cs, categories, category);
    });
  }
}
