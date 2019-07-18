import 'package:sembast/sembast.dart';
import 'package:sembast/src/api/query_ref.dart';
import 'package:sembast/src/api/record_ref.dart';
import 'package:sembast/src/common_import.dart';
import 'package:sembast/src/cooperator.dart';
import 'package:sembast/src/filter_impl.dart';
import 'package:sembast/src/finder_impl.dart';
import 'package:sembast/src/query_ref_impl.dart';
import 'package:sembast/src/record_impl.dart';

class QueryListenerController<K, V> {
  final SembastQueryRef<K, V> queryRef;
  StreamController<List<RecordSnapshot<K, V>>> _streamController;

  /// True when the first data has arrived
  bool get hasInitialData => _allMatching != null;

  bool get isClosed => _streamController.isClosed;
  // The current list
  List<RecordSnapshot<K, V>> list;
  List<ImmutableSembastRecord> _allMatching;

  SembastFinder get finder => queryRef.finder;

  SembastFilterBase get filter => finder?.filter as SembastFilterBase;

  void close() {
    _streamController?.close();
  }

  QueryListenerController(DatabaseListener listener, this.queryRef) {
    // devPrint('query $queryRef');
    _streamController =
        StreamController<List<RecordSnapshot<K, V>>>(onCancel: () {
      // Auto remove
      listener.removeQuery(this);
      close();
    });
  }

  Stream<List<RecordSnapshot<K, V>>> get stream => _streamController.stream;

  Future add(
      List<ImmutableSembastRecord> allMatching, Cooperator cooperator) async {
    if (isClosed) {
      return;
    }

    // Filter only
    _allMatching = allMatching;
    var list = await sortAndLimit(_allMatching, finder, cooperator);

    if (isClosed) {
      return;
    }
    // devPrint('adding $allMatching / limit $list / $finder');
    _streamController?.add(immutableListToSnapshots<K, V>(list));
  }

  void addError(dynamic error, StackTrace stackTrace) {
    if (isClosed) {
      return;
    }
    _streamController.addError(error, stackTrace);
  }

  // We are async safe here
  Future update(List<TxnRecord> txnRecords, Cooperator cooperator) async {
    if (isClosed) {
      return;
    }
    // Restart from the base we have for efficiency
    var allMatching = List<ImmutableSembastRecord>.from(_allMatching);
    bool hasChanges = false;
    for (var txnRecord in txnRecords) {
      if (isClosed) {
        return;
      }
      var ref = txnRecord.ref;

      bool _where(snapshot) {
        if (snapshot.ref == ref) {
          hasChanges = true;
          return true;
        }
        return false;
      }

      // Remove and reinsert if needed
      allMatching.removeWhere(_where);

      // By default matches if non-deleted
      bool matches = !txnRecord.deleted;
      if (matches && filter != null) {
        matches = filterMatchesRecord(filter, txnRecord.record);
      }

      if (matches) {
        hasChanges = true;
        // re-add
        allMatching.add(txnRecord.record);
      }

      await cooperator.cooperate();
    }
    if (isClosed) {
      return;
    }
    if (hasChanges) {
      await add(allMatching, cooperator);
    }
  }
}

class RecordListenerController<K, V> {
  bool hasInitialData = false;
  StreamController<RecordSnapshot<K, V>> _streamController;

  void close() {
    _streamController.close();
  }

  bool get isClosed => _streamController.isClosed;

  RecordListenerController(
      DatabaseListener listener, RecordRef<K, V> recordRef) {
    _streamController = StreamController<RecordSnapshot<K, V>>(onCancel: () {
      // devPrint('onCancel');
      // Auto remove
      listener.removeRecord(recordRef, this);
      close();
    });
  }

  Stream<RecordSnapshot<K, V>> get stream => _streamController.stream;

  void add(RecordSnapshot snapshot) {
    if (isClosed) {
      return;
    }
    hasInitialData = true;
    _streamController?.add(snapshot?.cast<K, V>());
  }

  void addError(dynamic error, StackTrace stackTrace) {
    if (isClosed) {
      return;
    }
    _streamController?.addError(error, stackTrace);
  }
}

class StoreListener {
  final _records = <dynamic, List<RecordListenerController>>{};
  final _queries = <QueryListenerController>[];

  RecordListenerController<K, V> addRecord<K, V>(
      RecordRef<K, V> recordRef, RecordListenerController<K, V> ctlr) {
    var key = recordRef.key;
    var list = _records[key];
    if (list == null) {
      list = <RecordListenerController>[];
      _records[key] = list;
    }
    list.add(ctlr);
    return ctlr;
  }

  QueryListenerController<K, V> addQuery<K, V>(
      QueryListenerController<K, V> ctlr) {
    _queries.add(ctlr);
    return ctlr;
  }

  void removeQuery(QueryListenerController ctlr) {
    ctlr.close();
    _queries.remove(ctlr);
  }

  void removeRecord(RecordRef recordRef, RecordListenerController ctlr) {
    ctlr.close();
    var key = recordRef.key;
    var list = _records[key];
    if (list != null) {
      list.remove(ctlr);
      if (list.isEmpty) {
        _records.remove(key);
      }
    }
  }

  List<RecordListenerController<K, V>> getRecord<K, V>(
      RecordRef<K, V> recordRef) {
    return _records[recordRef.key]?.cast<RecordListenerController<K, V>>();
  }

  /// Get list of query listeners, never null
  List<QueryListenerController<K, V>> getQuery<K, V>() {
    return _queries.cast<QueryListenerController<K, V>>();
  }

  bool get isEmpty => _records.isEmpty && _queries.isEmpty;
}

class DatabaseListener {
  final _stores = <StoreRef, StoreListener>{};

  bool get isNotEmpty => _stores.isNotEmpty;

  bool get isEmpty => _stores.isEmpty;

  RecordListenerController<K, V> addRecord<K, V>(RecordRef<K, V> recordRef) {
    var ctlr = RecordListenerController<K, V>(this, recordRef);
    var storeRef = recordRef.store;
    var store = _stores[storeRef];
    if (store == null) {
      store = StoreListener();
      _stores[storeRef] = store;
    }
    return store.addRecord<K, V>(recordRef, ctlr);
  }

  QueryListenerController<K, V> addQuery<K, V>(QueryRef<K, V> queryRef) {
    var ctlr = newQuery(queryRef);
    addQueryController(ctlr);
    return ctlr;
  }

  QueryListenerController<K, V> newQuery<K, V>(QueryRef<K, V> queryRef) {
    var ref = queryRef as SembastQueryRef<K, V>;
    var ctlr = QueryListenerController<K, V>(this, ref);
    return ctlr;
  }

  void addQueryController<K, V>(QueryListenerController<K, V> ctlr) {
    var storeRef = ctlr.queryRef.store;
    var store = _stores[storeRef];
    if (store == null) {
      store = StoreListener();
      _stores[storeRef] = store;
    }
    store.addQuery<K, V>(ctlr);
  }

  void removeRecord(RecordRef recordRef, RecordListenerController ctlr) {
    ctlr.close();
    var storeRef = recordRef.store;
    var store = _stores[storeRef];
    if (store != null) {
      store.removeRecord(recordRef, ctlr);
      if (store.isEmpty) {
        _stores.remove(storeRef);
      }
    }
  }

  void removeQuery(QueryListenerController ctlr) {
    ctlr.close();
    var storeRef = ctlr.queryRef.store;
    var store = _stores[storeRef];
    if (store != null) {
      store.removeQuery(ctlr);
      if (store.isEmpty) {
        _stores.remove(storeRef);
      }
    }
  }

  List<RecordListenerController<K, V>> getRecord<K, V>(
      RecordRef<K, V> recordRef) {
    return _stores[recordRef]
        .getRecord(recordRef)
        ?.cast<RecordListenerController<K, V>>();
  }

  StoreListener getStore(StoreRef ref) => _stores[ref];

  void close() {
    _stores.values.forEach((storeListener) {
      storeListener._queries.forEach((queryListener) {
        queryListener.close();
      });
      storeListener._records.values.forEach((recordListeners) {
        recordListeners.forEach((recordListener) => recordListener.close());
      });
    });
  }
}

class StoreListenerOperation {
  final StoreListener listener;
  final List<TxnRecord> txnRecords;

  StoreListenerOperation(this.listener, this.txnRecords);
}