import importlib.util
import sys
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

root = Path(__file__).parents[2] / 'infra/teacher/lambda'
sys.path.insert(0, str(root))
spec = importlib.util.spec_from_file_location('budget', root / 'budget.py')
budget = importlib.util.module_from_spec(spec)
sys.modules['budget'] = budget
spec.loader.exec_module(budget)


class BudgetTests(unittest.TestCase):
    @patch.dict('os.environ', {'TABLE': 'uploads', 'PIPELINE_SOFT_LIMIT_GBP': '8.00'})
    def test_reservation_updates_the_month_ledger_before_work(self):
        db = Mock()
        with patch.dict(sys.modules, {'boto3': Mock(client=Mock(return_value=db))}):
            self.assertTrue(budget.reserve_gbp('0.10', 'test-operation'))
        db.update_item.assert_called_once()
        self.assertIn('reserved_gbp', db.update_item.call_args.kwargs['UpdateExpression'])

    @patch.dict('os.environ', {'TABLE': 'uploads', 'PIPELINE_SOFT_LIMIT_GBP': '0.05'})
    def test_budget_condition_denies_work_before_calling_aws_service(self):
        class Limited(Exception):
            response = {'Error': {'Code': 'ConditionalCheckFailedException'}}
        db = Mock()
        db.update_item.side_effect = Limited()
        with patch.dict(sys.modules, {'boto3': Mock(client=Mock(return_value=db))}):
            self.assertFalse(budget.reserve_gbp('0.05', 'test-operation'))


if __name__ == '__main__':
    unittest.main()
