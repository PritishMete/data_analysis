"""Shared semantic schema intelligence for InsightFlow Data Workspace.

This package composes the existing schema_intelligence rule engine instead of
creating a second detector. It adds a privacy-safe semantic contract for
query planning and future cleaning/modeling layers.
"""
from .semantic_engine import SemanticField, SemanticSchema, SemanticSchemaEngine

__all__ = ["SemanticField", "SemanticSchema", "SemanticSchemaEngine"]
